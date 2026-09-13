import QtQuick
import Quickshell
import Quickshell.Services.Pam
import Quickshell.Wayland

Scope {
    id: root

    required property QtObject config

    signal unlocked()

    property bool locked: true
    property bool unlockHandled: false

    property string pendingPassword: ""
    property bool unlockInProgress: false
    property string statusMessage: ""

    readonly property var i18n: config.i18n || {}

    function log(t) { console.log("[" + Date.now() + "] Lock:", t) }

    Component.onCompleted: {
        log("Component.onCompleted")
        statusMessage = i18n.prompt || "Enter password"
    }

    WlSessionLock {
        id: sessionLock
        locked: root.locked

        WlSessionLockSurface {
            id: lockSurface
            color: config.data ? config.data.backgroundColor : "#000000"

            LockContent {
                anchors.centerIn: parent
                width: Math.min(
                    config.data && config.data.panel ? config.data.panel.widthMax : 360,
                    parent.width * 0.8
                )
                height: Math.min(120, parent.height * 0.5)
                statusMessage: root.statusMessage
                unlockInProgress: root.unlockInProgress
                responseVisible: pam.responseVisible
                config: root.config

                onPasswordSubmitted: function (password) {
                    root.tryUnlock(password)
                }

                onDismissRequested: {
                    log("onDismissRequested received")
                    if (root.config.data && root.config.data.debugAllowDismiss) {
                        pam.abort()
                        log("dismiss: setting root.locked = false")
                        root.locked = false
                    }
                }
            }
        }
    }

    PamContext {
        id: pam
        config: root.config.pamService
        configDirectory: "/etc/pam.d"
        user: Quickshell.env("USER") || Quickshell.env("LOGNAME") || ""

        onPamMessage: {
            log("PAM message: " + message + " (error=" + messageIsError + ")")
            watchdog.restart()
            if (message && message.length > 0) {
                statusMessage = message
            }
        }

        onResponseRequiredChanged: {
            if (responseRequired) {
                watchdog.restart()
                answerPrompt()
            }
        }

        onCompleted: function (result) {
            watchdog.stop()
            log("PamContext.onCompleted: result=" + result +
                " (Success=" + PamResult.Success + ")")
            if (result === PamResult.Success) {
                unlockInProgress = false
                statusMessage = i18n.unlocked || "Unlocked"
                log("PAM Success: setting root.locked = false")
                root.locked = false
            } else {
                unlockInProgress = false
                pendingPassword = ""
                if (result === PamResult.MaxTries) {
                    statusMessage = i18n.maxTries || "Too many attempts"
                } else {
                    statusMessage = i18n.authFailed || "Authentication failed"
                }
            }
        }

        onError: function (error) {
            watchdog.stop()
            unlockInProgress = false
            pendingPassword = ""
            statusMessage = i18n.authError || "Authentication error"
        }
    }

    // Watchdog: a PAM transaction can hang without ever asking anything
    // (slow module, hardware-key touch nobody makes, offline pam_sss). This
    // is an inactivity timer, not a wall-clock deadline — any PAM traffic
    // restarts it, so chatty stacks run as long as they need. On fire the
    // abort returns to a fresh prompt; it never unlocks.
    Timer {
        id: watchdog
        interval: config.data.pamWatchdogTimeoutMs
        repeat: false
        running: false
        onTriggered: {
            log("PAM watchdog: no PAM traffic for " + interval + "ms — aborting stuck transaction")
            pam.abort()
            unlockInProgress = false
            pendingPassword = ""
            statusMessage = i18n.timedOut || "Authentication timed out — try again"
        }
    }

    Component.onDestruction: {
        pam.abort()
    }

    Connections {
        target: sessionLock
        function onLockStateChanged() {
            log("sessionLock.locked changed: locked=" + sessionLock.locked +
                " secure=" + sessionLock.secure +
                " ourIntent=" + root.locked +
                " unlockHandled=" + root.unlockHandled)

            if (!sessionLock.locked && !root.unlockHandled) {
                if (root.locked) {
                    log("external invalidation detected (root.locked still true)")
                    console.warn("aerial-lock: lock invalidated externally by compositor")
                }
                root.unlockHandled = true
                log("emitting unlocked()")
                root.unlocked()
            }
        }
    }

    // Two-phase conversation: phase 1 sends the just-submitted password;
    // phase 2 (no pending password — PAM wants something else) surfaces
    // PAM's own message and waits for the user. The distinction keys on
    // "did PAM ask again?", never on matching prompt strings.
    function answerPrompt() {
        if (pendingPassword !== "") {
            var pw = pendingPassword
            pendingPassword = ""
            pam.respond(pw)
            unlockInProgress = true
            statusMessage = i18n.authenticating || "Authenticating..."
        } else {
            if (pam.message && pam.message.length > 0) {
                statusMessage = pam.message
            }
            unlockInProgress = false
        }
    }

    function tryUnlock(password) {
        log("tryUnlock: unlockInProgress=" + unlockInProgress +
            " pam.responseRequired=" + pam.responseRequired)
        if (unlockInProgress && pendingPassword === "") {
            return
        }

        pendingPassword = password

        if (pam.responseRequired) {
            log("tryUnlock: calling pam.respond")
            var response = pendingPassword
            pendingPassword = ""
            pam.respond(response)
            unlockInProgress = true
            statusMessage = i18n.authenticating || "Authenticating..."
            watchdog.restart()
        } else {
            log("tryUnlock: calling pam.start")
            watchdog.restart()
            if (!pam.start()) {
                watchdog.stop()
                pendingPassword = ""
                statusMessage = i18n.authError || "Authentication error"
                console.warn("aerial-lock: pam.start() failed for service", pam.config)
            }
        }
    }
}
