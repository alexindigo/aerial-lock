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

    property string passwordBuffer: ""
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
                config: root.config

                onPasswordSubmitted: function (password) {
                    root.tryUnlock(password)
                }

                onDismissRequested: {
                    log("onDismissRequested received")
                    if (root.config.data && root.config.data.debugAllowDismiss) {
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

        onResponseRequiredChanged: {
            if (responseRequired && passwordBuffer !== "") {
                respond(passwordBuffer)
                passwordBuffer = ""
                unlockInProgress = true
                statusMessage = i18n.authenticating || "Authenticating..."
            }
        }

        onCompleted: function (result) {
            log("PamContext.onCompleted: result=" + result +
                " (Success=" + PamResult.Success + ")")
            if (result === PamResult.Success) {
                unlockInProgress = false
                statusMessage = i18n.unlocked || "Unlocked"
                log("PAM Success: setting root.locked = false")
                root.locked = false
            } else {
                unlockInProgress = false
                passwordBuffer = ""
                if (result === PamResult.MaxTries) {
                    statusMessage = i18n.maxTries || "Too many attempts"
                } else {
                    statusMessage = i18n.authFailed || "Authentication failed"
                }
            }
        }

        onError: function (error) {
            unlockInProgress = false
            passwordBuffer = ""
            statusMessage = i18n.authError || "Authentication error"
        }
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

    function tryUnlock(password) {
        log("tryUnlock: unlockInProgress=" + unlockInProgress +
            " pam.responseRequired=" + pam.responseRequired)
        if (unlockInProgress) {
            return
        }

        passwordBuffer = password

        if (pam.responseRequired) {
            log("tryUnlock: calling pam.respond")
            pam.respond(password)
            passwordBuffer = ""
            unlockInProgress = true
            statusMessage = i18n.authenticating || "Authenticating..."
        } else {
            log("tryUnlock: calling pam.start")
            if (!pam.start()) {
                statusMessage = i18n.authError || "Authentication error"
                console.warn("aerial-lock: pam.start() failed for service", pam.config)
            }
        }
    }
}
