import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    id: root

    property bool engaged: false
    property bool releasing: false
    property bool completed: false

    function log(t) { console.log("[" + Date.now() + "] emergency-unlock:", t) }

    Component.onCompleted: {
        log("=== aerial-lock emergency unlock ===")
        log("Attempting to bind ext-session-lock-v1 and take over the current lock.")
        log("This will engage a new lock briefly, then release it cleanly.")
    }

    WlSessionLock {
        id: lock
        locked: true

        WlSessionLockSurface {
            color: "black"
        }
    }

    Connections {
        target: lock
        function onSecureStateChanged() {
            log("compositor state: secure=" + lock.secure + " locked=" + lock.locked)
            if (lock.secure && !root.engaged) {
                root.engaged = true
                log("SUCCESS: compositor confirmed lock engagement")
                log("scheduling release in 500ms")
                releaseTimer.start()
            }
        }
        function onLockStateChanged() {
            log("compositor state: locked=" + lock.locked + " secure=" + lock.secure)
            if (!lock.locked && root.releasing && !root.completed) {
                root.completed = true
                log("SUCCESS: compositor confirmed release")
                log("scheduling clean exit in 500ms")
                quitTimer.start()
            }
        }
    }

    Timer {
        id: releaseTimer
        interval: 500
        repeat: false
        onTriggered: {
            root.releasing = true
            log("setting lock.locked = false (releasing)")
            lock.locked = false
        }
    }

    Timer {
        id: quitTimer
        interval: 500
        repeat: false
        onTriggered: {
            log("clean exit")
            Qt.quit()
        }
    }

    Timer {
        interval: 3000
        running: true
        repeat: false
        onTriggered: {
            if (!root.engaged) {
                log("WARNING: compositor has not confirmed lock engagement after 3s")
                log("  Likely cause: another lock client (aerial-lock?) is still active.")
                log("  Suggested action: dismiss the existing lock, or retry with --purge")
            }
        }
    }

    Timer {
        interval: 10000
        running: true
        repeat: false
        onTriggered: {
            log("ERROR: 10s timeout reached, forcing exit")
            log("  Lock state may not have been recovered.")
            log("  Manual recovery paths:")
            log("  1. Ctrl+Alt+F2 for TTY, then pkill -f 'qs -p.*aerial-lock'")
            log("  2. Launch swaylock-plugin or your working locker and dismiss it")
            log("  3. Retry aerial-emergency-unlock --purge")
            Qt.quit()
        }
    }

    Connections {
        target: Quickshell
        function onLastWindowClosed() {
            log("Quickshell.lastWindowClosed received")
            Qt.quit()
        }
    }
}
