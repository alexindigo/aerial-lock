import QtQuick
import Quickshell

ShellRoot {
    settings.watchFiles: false
    Timer {
        interval: 20
        running: true
        onTriggered: {
            var ready = Quickshell.env("AERIAL_LOCK_CONNECTION_GUARD_PID") === String(Quickshell.processId)
            if (ready)
                console.log("GUARD_STARTUP_PID_MATCH")
            Qt.exit(ready ? 0 : 71)
        }
    }
}
