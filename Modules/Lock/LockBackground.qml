import QtQuick
import MpvQml

// Video background for a lock surface. Pure scenery: no config access, no
// PAM, no input. The parent (Lock.qml) injects items after load and calls
// shutdown() on unlock; playback errors surface as loadFailed for the
// parent to log.
Item {
    id: root

    // One mpv playlist in list order: {kind: "file"} loads the clip,
    // {kind: "dir"} expands to the directory's videos. The first playable
    // entry replaces, the rest append. Missing files/dirs are skipped by
    // mpv (error + advance), never a crash.
    property var items: []
    property bool stopped: false
    // Native media failure (core or renderer) is final for this background:
    // the surface keeps its solid colour and authentication is unaffected.
    property bool mediaFailed: false
    // Injected by Lock: the locker's private runtime directory for frame
    // grabs, and whether this background's accent is the consumed one.
    property string frameDirectory: ""
    property bool samplingActive: false

    signal loadFailed(string message)

    readonly property var filters: ["*.mp4", "*.mkv", "*.webm", "*.mov"]

    // d38: playback export for LockContext. The plugin has no
    // currentFilename Q_PROPERTY, but mpv's `playlist` marks the playing
    // entry — derive it from there ("" when nothing plays).
    readonly property real position: player.position
    readonly property real duration: player.duration
    readonly property bool hasVideo: player.hasVideo
    // d45: the sensed prominent color of the current frame (transparent
    // when unsensed). The 600 ms crossfade lives at the value's origin
    // (AccentSampler) and animates the whole downstream chain.
    readonly property color accentColor: sampler.accent
    readonly property string currentFilename: {
        var pl = player.playlist
        for (var i = 0; i < pl.length; i++) {
            if (pl[i] && pl[i].current && pl[i].filename)
                return pl[i].filename
        }
        // Single-file mode (player.source) never populates `playlist`.
        return player.source || ""
    }

    function shutdown() {
        if (stopped)
            return
        stopped = true
        sampler.shutdown()
        stopPlayback()
    }
    Component.onDestruction: shutdown()

    // The one place playback stops, at most once. Without a core there is
    // nothing to stop (stop() would only report an unavailable core).
    property bool playbackStopped: false
    function stopPlayback() {
        if (playbackStopped || !player.coreAvailable)
            return
        playbackStopped = true
        player.paused = true
        player.stop(false)
    }

    // Media failure is final for this background, i.e. for this lock: the
    // surface keeps its solid colour until unlock and the next lock tries
    // again. The player reports the failure itself (errorOccurred →
    // loadFailed), so this only retires the scenery. Playback is stopped too:
    // mpvqml keeps the core and the playback intent across a render failure,
    // so the hidden player would otherwise keep decoding, and a later
    // renderer recovery could resume video behind the solid colour.
    function mediaFailure() {
        if (mediaFailed)
            return
        mediaFailed = true
        sampler.shutdown()
        stopPlayback()
    }

    // Single drive point: the parent assigns items after
    // Component.onCompleted, so loading hangs off the property change,
    // not construction.
    function applySource() {
        if (stopped || mediaFailed || items.length === 0)
            return
        var first = true
        for (var i = 0; i < items.length; i++) {
            var it = items[i]
            if (!it || !it.path || it.path.length === 0)
                continue
            if (it.kind === "dir")
                player.loadDirectory(it.path, filters, first ? "replace" : "append", "name")
            else
                player.load(it.path, first ? "replace" : "append")
            first = false
        }
    }

    onItemsChanged: applySource()

    AccentSampler {
        id: sampler
        player: player
        trackKey: root.currentFilename
        shotDirectory: root.frameDirectory
        active: root.samplingActive
        onSamplingFailed: function (reason) { root.loadFailed(reason) }
    }

    MpvPlayer {
        id: player
        anchors.fill: parent
        enabled: false            // keys stay on the password field
        // Native readiness must be allowed before loading yields hasVideo.
        // The renderer's blank target exposes the solid surface until then.
        visible: !root.stopped && !root.mediaFailed
        mute: true
        fillMode: "preserveAspectCrop"
        // A lone file loops seamlessly (loopFile); anything else is a
        // playlist and loops as one.
        loopFile: root.items.length === 1
                  && root.items[0].kind === "file" ? "inf" : "no"
        loopPlaylist: "inf"

        onErrorOccurred: function (code, message) {
            root.loadFailed(message)
        }
        onInitializationFailed: root.mediaFailure()
        onRenderingFailed: root.mediaFailure()
    }
}
