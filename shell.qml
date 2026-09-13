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
                root.maybeLock()
            }
        }

        onFailedChanged: {
            log("cfg.onFailedChanged: failed=" + failed + " msg=" + errorMessage)
            if (failed) {
                console.warn("aerial-lock:", errorMessage)
                deferredQuit.start()
            }
        }
    }

    Services.PamProbe {
        id: pamProbe
        service: cfg.pamService
        configDirectory: cfg.pamConfigDirectory

        onCheckedChanged: {
            if (checked) {
                root.maybeLock()
            }
        }
    }

    // Deferred quit: Qt.quit() emitted during the startup cascade is a
    // no-op ("no receivers connected") — the engine wires it only once load
    // completes. A zero-delay timer fires right after, which still exits
    // promptly. Verified on quickshell 0.3.1.
    Timer {
        id: deferredQuit
        interval: 0
        repeat: false
        onTriggered: Qt.quit()
    }

    function maybeLock() {
        if (!cfg.ready || !pamProbe.checked) return
        if (!pamProbe.ok) {
            console.warn("aerial-lock: refusing to lock —", pamProbe.reason)
            console.warn("aerial-lock: run 'sudo make install', or set "
                       + "AERIAL_LOCK_PAM_SERVICE=login for development")
            deferredQuit.start()
            return
        }
        lockLoader.active = true
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
