import QtQuick
import MpvQml

// Video background for a lock surface. Pure scenery: no config access, no
// PAM, no input. The parent (Lock.qml) injects sourcePath (file pin) or
// directories (playlist union) after load and calls shutdown() on unlock;
// playback errors surface as loadFailed for the parent to log.
Item {
    id: root

    // File-pin mode: this one file, looped. Wins over directories when set.
    property string sourcePath: ""
    // Directory/union mode: first directory replaces, the rest append.
    // Missing or empty directories are a no-op in the plugin, not an error.
    property var directories: []

    signal loadFailed(string message)

    readonly property var filters: ["*.mp4", "*.mkv", "*.webm", "*.mov"]

    function shutdown() {
        player.paused = true
        player.stop(false)
    }

    // Single drive point for both source modes: the parent assigns the
    // properties after Component.onCompleted, so loading must hang off
    // property changes, not construction.
    function applySource() {
        if (sourcePath.length > 0) {
            player.source = sourcePath
            return
        }
        if (directories.length === 0)
            return
        player.loadDirectory(directories[0], filters, "replace", "name")
        for (var i = 1; i < directories.length; i++)
            player.loadDirectory(directories[i], filters, "append", "name")
    }

    onSourcePathChanged: applySource()
    onDirectoriesChanged: applySource()

    MpvPlayer {
        id: player
        anchors.fill: parent
        enabled: false            // keys stay on the password field
        visible: hasVideo         // solid surface color until a frame exists
        mute: true
        fillMode: "preserveAspectCrop"
        loopFile: root.sourcePath.length > 0 ? "inf" : "no"
        loopPlaylist: root.sourcePath.length > 0 ? "no" : "inf"

        onErrorOccurred: function (code, message) {
            root.loadFailed(message)
        }
    }
}
