import QtQuick
import Quickshell

ShellRoot {
    settings.watchFiles: false
    Timer {
        interval: 20
        running: true
        onTriggered: {
            if (Quickshell.env("AERIAL_LOCK_CONNECTION_GUARD_PID") !== String(Quickshell.processId)) {
                Qt.exit(72)
                return
            }
            console.log("CONNECTION_LOSS_READY")
            if (Quickshell.env("AERIAL_TEST_FULL_CALLER_FAULT") === "guard-logger")
                console.log("GUARD_TEST_BLOCK_LOGGER")
            if (Quickshell.env("AERIAL_LOCK_TEST_BLOCK_GUI") === "1") {
                // Fixture-only dispatch trap: a QML timer/Qt teardown cannot exit it.
                while (true) {}
            }
        }
    }
    Timer { interval: 20000; running: true; onTriggered: Qt.exit(1) }
}
