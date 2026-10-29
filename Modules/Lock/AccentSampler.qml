import QtQuick
import "AccentTone.js" as AccentTone

// AccentSampler (d45) — senses the playing video's prominent color and
// exports it as `accent`. Once per track, after a settle: mpv writes the
// current frame to a file (screenshot-to-file via commandAsync), the Canvas
// loads it by URL (its documented async image path — an Image *item* as a
// drawImage source samples fully transparent under this scene graph, and
// invisible items never paint at all; both verified in the d45 shakedown),
// and a 64x40 paint feeds AccentTone's histogram. `accent` is transparent
// while unsensed — themes keep their static palettes then. Pure scenery:
// no config, no PAM, no input.
//
// One completion-driven screenshot/image/paint transaction. Logical interest
// can retire while a file write remains outstanding; that never frees its slot.
Item {
    id: root
    property var player: null        // MpvPlayer, injected by LockBackground
    property string trackKey: ""     // LockBackground's currentFilename
    // Private directory owned by the launcher (never a shared temporary
    // directory). Empty or relative disables sampling.
    property string shotDirectory: ""
    // Only a background whose accent is consumed samples; an inactive
    // sampler stays idle and settles afresh when it becomes active.
    property bool active: false
    readonly property color accent: internal.accent
    signal samplingFailed(string reason)

    QtObject {
        id: internal
        // The one animation point: the 600 ms crossfade here animates the
        // whole downstream chain (background export → context → themes).
        // (A Behavior cannot sit on a readonly property — the animation's
        // writes would be rejected.)
        property color accent: "transparent"
        Behavior on accent { ColorAnimation { duration: 600 } }
        property bool stopped: false
        property int generation: 0
        property int attempt: 0
        property int shots: 0
        property bool eligible: false
        // The settle belongs to the transaction, not to video availability:
        // a settle (or due retry) that found no decoded video waits here, and
        // only then does newly available video re-arm a fresh settle.
        property bool awaitingVideo: false
        property var pending: null
        // Qt clears a typed QObject property and notifies when its receiver is
        // destroyed. A QObject wrapper nested in a JS ticket has no such signal.
        property QtObject pendingPlayer: null
        property string imageUrl: ""
        property string stage: "idle"
        // One reused file per sampler, so files are bounded by outputs, not
        // by tracks or shots. Each shot gets its own URL query, so the
        // URL-keyed image cache never serves an earlier frame; the previous
        // URL is unloaded before the next command (one ticket in flight).
        readonly property string instanceId: Math.floor(Math.random() * 1e9).toString(36)
        // A retired receiver may still complete its write later, so the
        // next shot after a receiver retirement uses a fresh file.
        property int fileEpoch: 0
        readonly property bool usable: root.active && root.shotDirectory.charAt(0) === "/"
        onUsableChanged: root.supersede()
        onPendingPlayerChanged: {
            var ticket = pending
            if (ticket && pendingPlayer === null) {
                ticket.discarded = true
                ticket.commandDone = true // receiver retirement, not write cancellation
                fileEpoch++
                commandDeadline.stop()
                root.retire(ticket, false)
            }
        }
    }

    function current(ticket) {
        return ticket && !internal.stopped && !ticket.discarded
                && ticket.generation === internal.generation
                && ticket.track === root.trackKey && ticket.player === root.player
    }

    function unload(url) {
        if (url.length > 0)
            canvas.unloadImage(url)
        if (internal.imageUrl === url)
            internal.imageUrl = ""
    }

    function retire(ticket, retry) {
        if (!ticket || internal.pending !== ticket || !ticket.commandDone)
            return
        unload(ticket.url)
        imageDeadline.stop()
        internal.pending = null
        internal.pendingPlayer = null
        internal.stage = "idle"
        if (internal.stopped)
            return
        if (retry && ticket.generation === internal.generation && internal.attempt < 3)
            backoff.restart()
        else if (ticket.generation !== internal.generation || ticket.player !== root.player)
            Qt.callLater(root.tryShot)
    }

    function supersede() {
        internal.generation++
        internal.attempt = 0
        internal.eligible = false
        internal.awaitingVideo = false
        internal.accent = "transparent"
        settleTimer.stop()
        backoff.stop()
        var ticket = internal.pending
        if (ticket) {
            ticket.discarded = true
            unload(ticket.url)
            if (ticket.commandDone)
                retire(ticket, false)
        }
        if (!internal.stopped && internal.usable && root.trackKey.length > 0)
            settleTimer.restart()
    }

    function tryShot() {
        if (internal.stopped || internal.pending || !internal.eligible || !internal.usable
                || internal.attempt >= 3 || root.trackKey.length === 0
                || !root.player)
            return
        if (!root.player.hasVideo) {
            // Playlist identity can precede decoded video. Never grab the
            // first frame the moment it appears; wait, then settle again.
            internal.awaitingVideo = true
            return
        }
        internal.attempt++
        internal.shots++
        var path = root.shotDirectory + "/accent-" + internal.instanceId
                + (internal.fileEpoch > 0 ? "-" + internal.fileEpoch : "") + ".jpg"
        var ticket = { id: 0, generation: internal.generation, track: root.trackKey,
                       player: root.player, path: path,
                       url: "file://" + path + "?shot=" + internal.shots,
                       discarded: false, commandDone: false }
        internal.pending = ticket
        internal.pendingPlayer = ticket.player
        internal.stage = "command"
        var id = ticket.player.commandAsync(["screenshot-to-file", path, "video"])
        if (id < 0) {
            ticket.commandDone = true
            samplingFailed("screenshot submission rejected")
            retire(ticket, true)
            return
        }
        ticket.id = id // allocated completion cannot arrive before this call returns
        commandDeadline.restart()
    }

    function commandFinished(id, error) {
        var ticket = internal.pending
        if (!ticket || ticket.id !== id || ticket.commandDone)
            return
        commandDeadline.stop()
        ticket.commandDone = true
        if (!current(ticket)) {
            retire(ticket, false)
            return
        }
        if (error < 0) {
            samplingFailed("screenshot command failed")
            retire(ticket, true)
            return
        }
        internal.stage = "image"
        internal.imageUrl = ticket.url
        imageDeadline.restart()
        canvas.loadImage(ticket.url, Qt.size(64, 40))
        inspectImage() // synchronous completion need not emit imageLoaded
    }

    function inspectImage() {
        var ticket = internal.pending
        if (!ticket || !ticket.commandDone || !current(ticket)
                || internal.imageUrl !== ticket.url)
            return
        if (canvas.isImageError(ticket.url)) {
            samplingFailed("screenshot image failed to load")
            retire(ticket, true)
        } else if (canvas.isImageLoaded(ticket.url) && canvas.available) {
            internal.stage = "paint"
            canvas.requestPaint()
        }
    }

    function shutdown() {
        if (internal.stopped)
            return
        internal.stopped = true
        internal.generation++
        internal.awaitingVideo = false
        settleTimer.stop()
        backoff.stop()
        commandDeadline.stop()
        imageDeadline.stop()
        var ticket = internal.pending
        if (ticket) {
            ticket.discarded = true
            unload(ticket.url)
            if (ticket.commandDone)
                retire(ticket, false)
        } else {
            unload(internal.imageUrl)
        }
    }

    onTrackKeyChanged: supersede()
    onPlayerChanged: supersede()
    onShotDirectoryChanged: if (internal.usable) supersede() // a new file location
    // Initial property values may be assigned in any order during creation.
    Component.onCompleted: supersede()
    Component.onDestruction: shutdown()

    Connections {
        target: internal.pending ? internal.pendingPlayer : root.player
        ignoreUnknownSignals: true
        function onAsyncCommandFinished(id, error, result) { root.commandFinished(id, error) }
    }
    function videoAvailabilityChanged() {
        // Only a settle that ended without video resumes; a pending settle,
        // an in-flight/finished transaction or an exhausted track does not.
        if (internal.stopped || internal.pending || !internal.awaitingVideo
                || !root.player || !root.player.hasVideo)
            return
        internal.awaitingVideo = false
        internal.eligible = false
        settleTimer.restart()
    }
    Connections {
        target: root.player
        ignoreUnknownSignals: true
        function onHasVideoChanged() { root.videoAvailabilityChanged() }
    }
    // Let mpv decode real content before grabbing (a shot at track start
    // can catch a black or stale frame).
    Timer {
        id: settleTimer
        interval: 1500
        onTriggered: { internal.eligible = true; root.tryShot() }
    }
    Timer {
        id: backoff
        interval: 300
        onTriggered: root.tryShot()
    }
    Timer {
        id: commandDeadline
        interval: 5000
        onTriggered: {
            var ticket = internal.pending
            if (ticket && !ticket.commandDone) {
                ticket.discarded = true
                if (ticket.generation === internal.generation)
                    internal.eligible = false
                root.samplingFailed("screenshot command deadline reached")
                // Keep the record/slot until a real completion or owner retirement.
            }
        }
    }
    Timer {
        id: imageDeadline
        interval: 2000
        onTriggered: {
            var ticket = internal.pending
            if (ticket && ticket.commandDone) {
                root.samplingFailed("screenshot image deadline reached")
                root.retire(ticket, true)
            }
        }
    }
    Canvas {
        id: canvas
        objectName: "accentCanvas"
        width: 64
        height: 40
        renderTarget: Canvas.Image
        renderStrategy: Canvas.Immediate
        // Must stay in the painted scene (invisible canvases never paint);
        // the full-surface MpvPlayer is declared after the sampler and
        // covers it. Nothing to see while there is no video.
        visible: root.player ? root.player.hasVideo : false
        onImageLoaded: root.inspectImage()
        onAvailableChanged: root.inspectImage()
        onPaint: {
            var ticket = internal.pending
            if (internal.stage !== "paint" || !root.current(ticket)
                    || internal.imageUrl !== ticket.url || !isImageLoaded(ticket.url))
                return
            var generation = ticket.generation
            var url = ticket.url
            var retry = false
            try {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                ctx.drawImage(url, 0, 0, width, height)
                var pixels = ctx.getImageData(0, 0, width, height).data
                var seed = AccentTone.seedFromPixels(pixels, width, height)
                if (internal.pending === ticket && root.current(ticket)
                        && generation === internal.generation)
                    internal.accent = seed ? Qt.hsla(seed.h, seed.s, seed.l, 1) : "transparent"
            } catch (error) {
                retry = true
                root.samplingFailed("screenshot paint failed")
            } finally {
                root.unload(url) // captured URL, even if external delivery superseded it
                root.retire(ticket, retry)
            }
        }
    }
}
