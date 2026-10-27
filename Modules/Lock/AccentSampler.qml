import QtQuick
import "AccentTone.js" as AccentTone

// AccentSampler (d45) — senses the playing video's prominent color and
// exports it as `accent`. Once per track: mpv writes the current frame to
// a fresh tmpfs file (screenshot-to-file via commandAsync), the Canvas
// loads it by URL (its documented async image path — an Image *item* as a
// drawImage source samples fully transparent under this scene graph, and
// invisible items never paint at all; both verified in the d45 shakedown),
// and a 64x40 paint feeds AccentTone's histogram. `accent` is transparent
// while unsensed — themes keep their static palettes then. Pure scenery:
// no config, no PAM, no input.
Item {
    id: root

    property var player: null        // MpvPlayer, injected by LockBackground
    property string trackKey: ""     // LockBackground's currentFilename

    readonly property bool videoAvailable: player ? player.hasVideo : false
    readonly property color accent: internal.accent

    QtObject {
        id: internal
        // The one animation point: the 600 ms crossfade here animates the
        // whole downstream chain (background export → context → themes).
        // (A Behavior cannot sit on a readonly property — the animation's
        // writes would be rejected.)
        property color accent: "transparent"
        Behavior on accent { ColorAnimation { duration: 600 } }
        property int attempt: 0
        property int shots: 0
        // One tmpfs jpg per shot (a fresh URL per attempt sidesteps the
        // canvas's URL-keyed image cache entirely); gone on reboot — QML
        // has no delete API, recorded as accepted litter in the d45 plan.
        readonly property string shotBase: "/tmp/aerial-lock-accent-"
            + Math.floor(Math.random() * 1e9).toString(36)
        property string shotUrl: ""
    }

    function resetTrackSensing() {
        // Invalidate the entire old shot pipeline, including cached paints.
        settleTimer.stop()
        writeTimer.stop()
        pollTimer.stop()
        internal.shotUrl = ""
        internal.attempt = 0
        internal.accent = "transparent"
    }

    onTrackKeyChanged: {
        resetTrackSensing()
        if (root.trackKey.length > 0)
            settleTimer.restart()
    }

    onVideoAvailableChanged: {
        // Playlist identity can precede decoded video. Resume only a track
        // whose initial settle ended without ever starting a shot pipeline.
        if (root.videoAvailable && root.trackKey.length > 0 && internal.attempt === 0
                && !settleTimer.running && !writeTimer.running && !pollTimer.running)
            settleTimer.start()
    }

    // Let mpv decode real content before grabbing (a shot at track start
    // can catch a black or stale frame).
    Timer {
        id: settleTimer
        interval: 1500
        repeat: false
        onTriggered: root.tryShot()
    }

    function tryShot() {
        if (!root.videoAvailable)
            return
        internal.attempt += 1
        internal.shots += 1
        var path = internal.shotBase + "-" + internal.shots + ".jpg"
        internal.shotUrl = "file://" + path
        root.player.commandAsync(["screenshot-to-file", path, "video"])
        writeTimer.restart()   // mpv writes asynchronously — load after it lands
    }

    Timer {
        id: writeTimer
        interval: 450
        repeat: false
        onTriggered: {
            canvas.loadImage(internal.shotUrl)   // async; pollTimer watches state
            pollTimer.restart()
        }
    }

    // The canvas image cache is URL-keyed, so a failed load must not be
    // retried on the same URL: re-shoot instead (fresh file, fresh URL),
    // up to three attempts per track.
    Timer {
        id: pollTimer
        interval: 300
        repeat: false
        onTriggered: {
            if (canvas.isImageLoaded(internal.shotUrl)) {
                canvas.requestPaint()
            } else if (internal.attempt < 3) {
                root.tryShot()
            }
            // Out of attempts: accent stays transparent until the next
            // track change re-triggers sensing.
        }
    }

    Canvas {
        id: canvas
        width: 64
        height: 40
        // Must stay in the painted scene (invisible canvases never paint);
        // the full-surface MpvPlayer is declared after the sampler and
        // covers it. Nothing to see while there is no video.
        visible: root.videoAvailable
        onPaint: {
            // Visibility-triggered paints can precede the first load.
            if (!isImageLoaded(internal.shotUrl))
                return
            var ctx = getContext("2d")
            ctx.drawImage(internal.shotUrl, 0, 0, width, height)
            var d = ctx.getImageData(0, 0, width, height).data
            var seed = AccentTone.seedFromPixels(d, width, height)
            console.log("AccentSampler: seed=" + (seed ? JSON.stringify(seed) : "none"))
            internal.accent = seed ? Qt.hsla(seed.h, seed.s, seed.l, 1) : "transparent"
        }
    }
}
