import QtQuick
import Quickshell
import Quickshell.Services.Pam
import Quickshell.Wayland

Scope {
    id: root

    required property QtObject config
    required property QtObject logger

    signal unlocked()

    property bool locked: true
    property bool unlockHandled: false

    property string pendingPassword: ""
    property bool unlockInProgress: false
    property bool attemptCancelled: false
    property string statusMessage: ""
    property int authState: authIdle

    readonly property int authIdle: 0
    readonly property int authPrompting: 1
    readonly property int authAuthenticating: 2
    readonly property int authFailed: 3
    readonly property int authMaxTries: 4
    readonly property int authError: 5
    readonly property int authSuccess: 6
    readonly property bool authIsError: authState === authFailed
            || authState === authMaxTries
            || authState === authError

    readonly property var i18n: config.i18n || {}

    property string panelScreenName: ""

    function resolvePanelScreen() {
        var screens = Quickshell.screens
        if (!screens || screens.length === 0)
            return ""
        return screens[0].name
    }

    Component.onCompleted: {
        logger.d("Lock", "Component.onCompleted")
        root.panelScreenName = root.resolvePanelScreen()
        authState = authPrompting
        statusMessage = i18n.prompt || "Enter password"
    }

    WlSessionLock {
        id: sessionLock
        locked: root.locked

        WlSessionLockSurface {
            id: lockSurface
            color: config.data ? config.data.backgroundColor : "#000000"

            readonly property bool hostsPanel: {
                if (!Quickshell.screens || Quickshell.screens.length <= 1)
                    return true
                return lockSurface.screen
                       && lockSurface.screen.name === root.panelScreenName
            }

            LockContent {
                anchors.fill: parent
                visible: lockSurface.hostsPanel
                enabled: lockSurface.hostsPanel
                focus: lockSurface.hostsPanel
                statusMessage: root.statusMessage
                unlockInProgress: root.unlockInProgress
                responseVisible: pam.responseVisible
                config: root.config
                logger: root.logger
                isErrorState: root.authIsError

                onPasswordSubmitted: function (password) {
                    root.tryUnlock(password)
                }

                onDismissRequested: {
                    logger.d("Lock", "onDismissRequested received")
                    if (root.config.buildFlags.debugAllowDismiss) {
                        root.attemptCancelled = true
                        pam.abort()
                        logger.d("Lock", "dismiss: setting root.locked = false")
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

        // Conversation is keyed on pamMessage, emitted per message; the
        // change-gated responseRequiredChanged fires only once per
        // conversation on quickshell 0.3.1, so it never sees prompt 2+.
        onPamMessage: {
            logger.d("Lock", "PAM message: " + message + " (error=" + messageIsError + ")")
            watchdog.restart()
            if (responseRequired) {
                // PAM is asking for input.
                if (pendingPassword !== "") {
                    // Phase 1: the just-submitted password answers this
                    // prompt. Clear before respond so the property holds a
                    // value only across the async gap.
                    var pw = pendingPassword
                    pendingPassword = ""
                    pam.respond(pw)
                    unlockInProgress = true
                    authState = authAuthenticating
                    statusMessage = i18n.authenticating || "Authenticating..."
                } else {
                    // Phase 2: PAM wants something else — surface its own
                    // message and wait for the user.
                    unlockInProgress = false       // waiting on USER, not PAM
        authState = authPrompting
                    if (message && message.length > 0) {
                        statusMessage = message
                    }
                    // echo mode follows pam.responseVisible (LockContent reads
                    // pam.responseVisible directly); field re-enables via the
                    // unlockInProgress binding.
                }
            } else {
                // Informational (fingerprint "touch the sensor", etc.) —
                // PAM is still working; field stays disabled.
                if (message && message.length > 0) {
                    statusMessage = message
                }
            }
        }

        onCompleted: function (result) {
            watchdog.stop()
            if (attemptCancelled) {
                logger.d("Lock", "PamContext.onCompleted ignored: attempt cancelled")
                return
            }
            logger.d("Lock", "PamContext.onCompleted: result=" + result +
                " (Success=" + PamResult.Success + ")")
                if (result === PamResult.Success) {
                unlockInProgress = false
                authState = authSuccess
                statusMessage = i18n.unlocked || "Unlocked"
                logger.d("Lock", "PAM Success: setting root.locked = false")
                root.locked = false
            } else {
                unlockInProgress = false
                pendingPassword = ""
                if (result === PamResult.MaxTries) {
                    authState = authMaxTries
                    statusMessage = i18n.maxTries || "Too many attempts"
                } else {
                    authState = authFailed
                    statusMessage = i18n.authFailed || "Authentication failed"
                }
            }
        }

        onError: function (error) {
            watchdog.stop()
            if (attemptCancelled) {
                logger.d("Lock", "PamContext.onError ignored: attempt cancelled")
                return
            }
            unlockInProgress = false
            pendingPassword = ""
            authState = authError
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
            logger.d("Lock", "PAM watchdog: no PAM traffic for " + interval + "ms — aborting stuck transaction")
            root.attemptCancelled = true
            pam.abort()
            unlockInProgress = false
            pendingPassword = ""
            authState = authError
            statusMessage = i18n.timedOut || "Authentication timed out — try again"
        }
    }

    Component.onDestruction: {
        root.attemptCancelled = true
        pam.abort()
    }

    Connections {
        target: sessionLock
        function onSecureStateChanged() {
            logger.d("Lock", "sessionLock.secure changed: secure=" + sessionLock.secure)
        }
        function onLockStateChanged() {
            logger.d("Lock", "sessionLock.locked changed: locked=" + sessionLock.locked +
                " secure=" + sessionLock.secure +
                " ourIntent=" + root.locked +
                " unlockHandled=" + root.unlockHandled)

            if (!sessionLock.locked && !root.unlockHandled) {
                if (root.locked) {
                    logger.d("Lock", "external invalidation detected (root.locked still true)")
                    logger.w("aerial-lock", "lock invalidated externally by compositor")
                }
                root.unlockHandled = true
                logger.d("Lock", "emitting unlocked()")
                root.unlocked()
            }
        }
    }

    function tryUnlock(password) {
        logger.d("Lock", "tryUnlock: unlockInProgress=" + unlockInProgress +
            " pam.responseRequired=" + pam.responseRequired)
        if (unlockInProgress && pendingPassword === "") {
            return
        }

        pendingPassword = password

        if (pam.responseRequired) {
            logger.d("Lock", "tryUnlock: calling pam.respond")
            var response = pendingPassword
            pendingPassword = ""
            pam.respond(response)
            unlockInProgress = true
            authState = authAuthenticating
            statusMessage = i18n.authenticating || "Authenticating..."
            watchdog.restart()
        } else {
            logger.d("Lock", "tryUnlock: calling pam.start")
            watchdog.restart()
            attemptCancelled = false
            if (!pam.start()) {
                watchdog.stop()
                pendingPassword = ""
                authState = authError
                statusMessage = i18n.authError || "Authentication error"
                logger.w("aerial-lock", "pam.start() failed for service " + pam.config)
            } else {
                authState = authAuthenticating
            }
        }
    }
}
