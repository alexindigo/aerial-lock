import QtQuick
import Quickshell
import "Modules/Lock" as LockModule
import "Services" as Services

ShellRoot {
    id: root

    function log(t) { console.log("[" + Date.now() + "] shell:", t) }

    Services.ConfigStore {
        id: cfg

        onReadyChanged: {
            log("cfg.onReadyChanged: ready=" + ready)
            if (ready) {
                lockLoader.active = true
            }
        }

        onFailedChanged: {
            log("cfg.onFailedChanged: failed=" + failed + " msg=" + errorMessage)
            if (failed) {
                console.warn("aerial-lock:", errorMessage)
                Qt.quit()
            }
        }
    }

    Loader {
        id: lockLoader
        active: false
        sourceComponent: Component {
            LockModule.Lock {
                config: cfg
                onUnlocked: {
                    root.log("Lock.onUnlocked received")
                    lockLoader.active = false
                    root.log("lockLoader.active set to false")
                    fallbackQuit.start()
                    root.log("fallbackQuit.start called, interval=" + fallbackQuit.interval)
                }
            }
        }
    }

    Timer {
        id: fallbackQuit
        interval: cfg.data && cfg.data.fallbackQuitMs ? cfg.data.fallbackQuitMs : 3000
        repeat: false
        onTriggered: {
            log("fallbackQuit.onTriggered")
            console.warn("aerial-lock: lastWindowClosed did not fire; forcing exit")
            Qt.quit()
        }
    }

    Connections {
        target: Quickshell
        function onLastWindowClosed() {
            log("Quickshell.lastWindowClosed received")
            fallbackQuit.stop()
            log("fallbackQuit stopped, calling Qt.quit()")
            Qt.quit()
        }
    }
}
