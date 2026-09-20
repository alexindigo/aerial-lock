import QtQuick
import Quickshell
import "Modules/Lock" as LockModule
import "Services" as Services

ShellRoot {
    id: root

    Binding {
        target: Services.Logger
        property: "verbose"
        value: cfg.buildFlags.verbose
               || Quickshell.env("AERIAL_LOCK_VERBOSE") === "1"
    }

    Services.ConfigStore {
        id: cfg

        onReadyChanged: {
            Services.Logger.d("shell", "cfg.onReadyChanged: ready=" + ready)
            if (ready) {
                root.maybeLock()
            }
        }

        onFailedChanged: {
            Services.Logger.d("shell", "cfg.onFailedChanged: failed=" + failed
                              + " msg=" + errorMessage)
            if (failed) {
                Services.Logger.w("aerial-lock", errorMessage)
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
            Services.Logger.w("aerial-lock", "refusing to lock — " + pamProbe.reason)
            Services.Logger.w("aerial-lock", "run 'sudo make install', or set "
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
                logger: Services.Logger
                onUnlocked: {
                    Services.Logger.d("shell", "Lock.onUnlocked received")
                    lockLoader.active = false
                    Services.Logger.d("shell", "lockLoader.active set to false")
                    fallbackQuit.start()
                    Services.Logger.d("shell", "fallbackQuit.start called, interval="
                                      + fallbackQuit.interval)
                }
            }
        }
    }

    Timer {
        id: fallbackQuit
        interval: cfg.data && cfg.data.fallbackQuitMs ? cfg.data.fallbackQuitMs : 3000
        repeat: false
        onTriggered: {
            Services.Logger.d("shell", "fallbackQuit.onTriggered")
            Services.Logger.w("aerial-lock", "lastWindowClosed did not fire; forcing exit")
            Qt.quit()
        }
    }

    Connections {
        target: Quickshell
        function onLastWindowClosed() {
            Services.Logger.d("shell", "Quickshell.lastWindowClosed received")
            fallbackQuit.stop()
            Services.Logger.d("shell", "fallbackQuit stopped, calling Qt.quit()")
            Qt.quit()
        }
    }
}
