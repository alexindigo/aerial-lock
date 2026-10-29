import QtQuick
import Quickshell
import MpvQml

ShellRoot {
    id: root
    settings.watchFiles: false
    property bool armed: false
    Window {
        width: 320
        height: 240
        visible: true
        Loader {
            id: loader
            anchors.fill: parent
            sourceComponent: MpvPlayer {
                source: Quickshell.env("AERIAL_LOCK_TEST_VIDEO")
                mute: true
                loopFile: "inf"
                onPositionChanged: {
                    if (root.armed || !hasVideo || !rendererReady || position < 0.2) return
                    if (Quickshell.env("AERIAL_LOCK_CONNECTION_GUARD_PID") !== String(Quickshell.processId)) {
                        Qt.exit(72)
                        return
                    }
                    root.armed = true
                    console.log("CONNECTION_LOSS_VIDEO_READY")
                    if (Quickshell.env("AERIAL_TEST_FULL_CALLER_FAULT") === "guard-retirement") {
                        Qt.callLater(function () {
                            loader.active = false
                            // Allow scenegraph release before holding dispatch.
                            retirementBlock.start()
                        })
                    } else if (Quickshell.env("AERIAL_LOCK_TEST_BLOCK_GUI") === "1") {
                        while (true) {}
                    }
                }
            }
        }
    }
    Timer {
        id: retirementBlock
        interval: 500
        onTriggered: {
            console.log("CONNECTION_LOSS_RETIREMENT_GUI_HELD")
            while (true) {}
        }
    }
    Timer { interval: 20000; running: true; onTriggered: Qt.exit(1) }
}
