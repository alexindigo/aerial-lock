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

    // Deferred quit, two call sites. Startup: Qt.quit() emitted during the
    // startup cascade is a no-op ("no receivers connected") — the engine
    // wires it only once load completes. Unlock (d27): the teardown
    // contract exits here, on the unlock event.
    //
    // interval 0 cannot outrun the Wayland flush of unlock_and_destroy:
    // qtwayland connects the event dispatcher's aboutToBlock/awake signals
    // to QWaylandDisplay::flushRequests() → wl_display_flush (qtbase 6.11.2,
    // src/plugins/platforms/wayland/qwaylandintegration.cpp:217-218), and
    // both stock dispatchers emit at least one of the two between any event
    // dispatch and the next (qeventdispatcher_glib.cpp:389,409;
    // qeventdispatcher_unix.cpp:438,452) — so the marshal is on the wire
    // before this timer's Qt.quit() runs. Corroborated by the d27
    // WAYLAND_DEBUG=1 stress loop (20/20 traces: unlock_and_destroy
    // written before disconnect).
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
                    deferredQuit.start()
                    fallbackQuit.start()
                    Services.Logger.d("shell", "deferredQuit and fallbackQuit started")
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
            Services.Logger.w("aerial-lock", "deferred exit did not complete; retrying quit")
            Qt.quit()
        }
    }

    // No lastWindowClosed-based exit. Qt emits lastWindowClosed only from
    // an accepted QEvent::Close; Quickshell destroys session-lock surfaces
    // via deleteLater(), never closes them (noctalia-qs
    // src/wayland/session_lock.cpp:144); and quitOnLastWindowClosed is
    // disabled at launch (noctalia-qs src/launch/launch.cpp:263). Exit is
    // therefore explicit and deferred-on-unlock — deferredQuit above.
}
