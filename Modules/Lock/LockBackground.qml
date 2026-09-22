import QtQuick
import MpvQml

// Video background for a lock surface. Pure scenery: no config access, no
// PAM, no input. The parent (Lock.qml) injects sourcePath/isDirectory after
// load and calls shutdown() on unlock; playback errors surface as
// loadFailed for the parent to log.
Item {
    id: root

    property string sourcePath: ""
    property bool isDirectory: false

    signal loadFailed(string message)

    function shutdown() {
        player.paused = true
        player.stop(false)
    }

    // Single drive point for both source modes: the parent assigns the two
    // properties after Component.onCompleted, so loading must hang off
    // property changes, not construction.
    function applySource() {
        if (sourcePath.length === 0)
            return
        if (isDirectory)
            player.loadDirectory(sourcePath,
                                 ["*.mp4", "*.mkv", "*.webm", "*.mov"],
                                 "replace", "name")
        else
            player.source = sourcePath
    }

    onSourcePathChanged: applySource()
    onIsDirectoryChanged: applySource()

    MpvPlayer {
        id: player
        anchors.fill: parent
        enabled: false            // keys stay on the password field
        visible: hasVideo         // solid surface color until a frame exists
        mute: true
        fillMode: "preserveAspectCrop"
        loopFile: root.isDirectory ? "no" : "inf"
        loopPlaylist: root.isDirectory ? "inf" : "no"

        onErrorOccurred: function (code, message) {
            root.loadFailed(message)
        }
    }
}
