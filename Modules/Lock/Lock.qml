import QtQuick
import Quickshell
import Quickshell.Services.Pam
import Quickshell.Wayland
import "../../Services"

Scope {
    id: root

    required property ConfigStore config
    required property Logger logger

    signal unlocked()

    property bool locked: true
    property bool unlockHandled: false

    // d43: the response accepted from the shared draft, queued for PAM's
    // first prompt. null = no queued response (distinct from an empty
    // answer: an empty initial submit starts PAM without queueing, while
    // an empty answer to an already-active prompt is submitted). Cleared
    // before pam.respond, and on failure, abort and teardown.
    property var acceptedResponse: null
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

    readonly property var i18n: config.i18n

    property string panelScreenName: ""
    property bool themeFallbackPinned: false
    property bool themeTopicsSet: false

    // Video background resolution (d36/d40): SourceCache publishes ONE
    // frozen playlist per lock after its nonblocking inventory resolves
    // (theme topics applied, 2000 ms deadline). Solid background while it
    // resolves; authentication never waits on it. LockBackground.qml is
    // the only MpvQml importer and only activates with a nonempty list —
    // libmpv never starts for nothing. qt6-mpvqml itself is a hard
    // dependency (README).
    readonly property var bgItems: sourceCache.playlist
    readonly property bool hasBackground: sourceCache.resolved && bgItems.length > 0

    SourceCache {
        id: sourceCache
        config: root.config
    }

    // d38: the one context object the panel (and future themes) consume.
    // Lock.qml owns every binding into it; LockContext itself knows no
    // PAM, no MpvQml, no pixels.
    //
    // Grouped-property syntax on alias groups (auth.status: …) compiles
    // under qmllint but the runtime rejects it ("Cannot assign to
    // non-existent property") — aliases carry no static group type. Bind
    // via Binding elements instead.
    LockContext {
        id: lockContext

        Component.onCompleted: {
            submitRequested.connect(root.tryUnlock)
            dismissRequested.connect(root.dismissRequested)
        }
    }

    Binding { target: lockContext.auth; property: "status"; value: root.statusMessage }
    Binding { target: lockContext.auth; property: "inProgress"; value: root.unlockInProgress }
    Binding { target: lockContext.auth; property: "isError"; value: root.authIsError }
    // PAM retains the previous echo mode after completion/abort. It is
    // meaningful only for a response requested by the active conversation.
    Binding { target: lockContext.auth; property: "responseVisible"; value: pam.active && pam.responseRequired && pam.responseVisible }
    Binding { target: lockContext.auth; property: "maxResponseSize"; value: config.pamLimits.maxResponseSize }
    Binding { target: lockContext.auth; property: "dismissAvailable"; value: config.buildFlags.debugAllowDismiss }

    Binding { target: lockContext.session; property: "outputName"; value: root.panelScreenName }
    Binding { target: lockContext.session; property: "loginName"; value: pam.user }
    Binding { target: lockContext.session; property: "avatarPath"; value: {
            var home = Quickshell.env("HOME")
            return home && home.length > 0 ? home + "/.face" : ""
        } }

    // d40 presentation projections: the panel and themes read metrics,
    // colors and labels from the context alone — neither ConfigStore nor
    // Logger crosses into theme code. Labels carry the shipped English
    // fallback so a theme never renders an empty prompt.
    Binding { target: lockContext.panel; property: "widthMax"; value: config.data.panel.widthMax }
    Binding { target: lockContext.panel; property: "fieldHeight"; value: config.data.panel.fieldHeight }
    Binding { target: lockContext.panel; property: "radius"; value: config.data.panel.radius }
    Binding { target: lockContext.panel; property: "fieldRadius"; value: config.data.panel.fieldRadius }
    Binding { target: lockContext.panel; property: "outerMargin"; value: config.data.panel.outerMargin }
    Binding { target: lockContext.panel; property: "spacing"; value: config.data.panel.spacing }
    Binding { target: lockContext.panel; property: "fontSize"; value: config.data.panel.fontSize }

    Binding { target: lockContext.colors; property: "text"; value: config.data.colors.text }
    Binding { target: lockContext.colors; property: "textError"; value: config.data.colors.textError }
    Binding { target: lockContext.colors; property: "input"; value: config.data.colors.input }
    Binding { target: lockContext.colors; property: "panelFill"; value: config.data.colors.panelFill }
    Binding { target: lockContext.colors; property: "panelBorder"; value: config.data.colors.panelBorder }
    Binding { target: lockContext.colors; property: "fieldFill"; value: config.data.colors.fieldFill }
    Binding { target: lockContext.colors; property: "fieldBorderFocused"; value: config.data.colors.fieldBorderFocused }
    Binding { target: lockContext.colors; property: "fieldBorder"; value: config.data.colors.fieldBorder }

    Binding { target: lockContext.labels; property: "prompt"; value: i18n.prompt || "Enter password" }
    Binding { target: lockContext.labels; property: "authenticating"; value: i18n.authenticating || "Authenticating..." }
    Binding { target: lockContext.labels; property: "authFailed"; value: i18n.authFailed || "Authentication failed" }
    Binding { target: lockContext.labels; property: "maxTries"; value: i18n.maxTries || "Too many attempts" }
    Binding { target: lockContext.labels; property: "authError"; value: i18n.authError || "Authentication error" }
    Binding { target: lockContext.labels; property: "timedOut"; value: i18n.timedOut || "Authentication timed out — try again" }
    Binding { target: lockContext.labels; property: "dismissDebug"; value: i18n.dismissDebug || "Dismiss (debug)" }
    Binding { target: lockContext.labels; property: "unlocked"; value: i18n.unlocked || "Unlocked" }

    Connections {
        target: lockContext.video
        function onPathChanged() { root.updateVideoInfo(lockContext.video.path) }
    }

    Connections {
        target: lockContext.video
        function onPositionChanged() { root.updatePoi(lockContext.video.position) }
    }

    function dismissRequested() {
        logger.d("Lock", "dismissRequested received")
        if (root.config.buildFlags.debugAllowDismiss) {
            root.attemptCancelled = true
            pam.abort()
            logger.d("Lock", "dismiss: setting root.locked = false")
            root.locked = false
        }
    }

    function updateVideoInfo(path) {
        var info = sourceCache.lookup(path)
        lockContext.video.id = (info && info.id) ? info.id : ""
        lockContext.video.name = (info && info.name) ? info.name : ""
        lockContext.video.secondaryName = (info && info.secondaryName) ? info.secondaryName : ""
        lockContext.video.scene = (info && info.scene) ? info.scene : ""
        lockContext.video.timeOfDay = (info && info.timeOfDay) ? info.timeOfDay : ""
        lockContext.video.sourceName = (info && info.sourceName) ? info.sourceName : ""
        lockContext.poi.map = (info && info.poi) ? info.poi : ({})
        logger.d("LockContext", "video: id=" + lockContext.video.id
                 + " name=" + lockContext.video.name
                 + " source=" + lockContext.video.sourceName)
        updatePoi(lockContext.video.position)
    }

    function updatePoi(position) {
        var map = lockContext.poi.map
        var text = ""
        var at = -1
        var nums = []
        for (var k in map)
            nums.push(Number(k))
        nums.sort(function (a, b) { return a - b })
        for (var j = 0; j < nums.length; j++) {
            if (position >= nums[j])
                at = nums[j]
            else
                break
        }
        if (at >= 0)
            text = map[String(at)] || ""
        if (lockContext.poi.text !== text || lockContext.poi.at !== at) {
            lockContext.poi.text = text
            lockContext.poi.at = at
            logger.d("LockContext", "poi: text=\"" + text + "\" at=" + at
                     + " position=" + position.toFixed(1))
        }
    }

    Compositor {
        id: compositor
    }

    function resolvePanelScreen() {
        var screens = Quickshell.screens
        if (!screens || screens.length === 0)
            return ""
        if (screens.length === 1)
            return screens[0].name
        var focused = compositor.focusedOutputName
        if (focused && focused.length > 0) {
            for (var i = 0; i < screens.length; i++) {
                if (screens[i].name === focused)
                    return focused
            }
            logger.w("aerial-lock", "focused output \"" + focused
                     + "\" does not match any known screen; using "
                     + screens[0].name)
        }
        return screens[0].name
    }

    function tryResolvePanel() {
        if (root.panelScreenName !== "")
            return
        if (compositor.focusedOutputName !== "") {
            root.panelScreenName = root.resolvePanelScreen()
            return
        }
        if (!compositor.backendReady)
            return
        if (compositor.backendName === "none") {
            root.panelScreenName = root.resolvePanelScreen()
            return
        }
        resolveGrace.restart()
    }

    Timer {
        id: resolveGrace
        interval: 50
        repeat: false
        onTriggered: {
            if (root.panelScreenName === "")
                root.panelScreenName = root.resolvePanelScreen()
        }
    }

    Component.onCompleted: {
        logger.d("Lock", "Component.onCompleted")
        root.tryResolvePanel()
        root.stampPreferred()
        authState = authPrompting
        statusMessage = i18n.prompt || "Enter password"
    }

    // d37: stamp preferredResolution on lock start when outputs are
    // visible (ShellScreen.height is the logical height). The write is
    // existence-only — maybeWritePreferred re-reads the user file and
    // no-ops if the key is already there, valid or not. With no screens
    // (shouldn't happen under Wayland) there is no write.
    function stampPreferred() {
        if (config.data.preferredResolution !== undefined)
            return
        var screens = Quickshell.screens
        if (!screens || screens.length === 0)
            return
        var maxH = 0
        for (var i = 0; i < screens.length; i++) {
            if (screens[i].height > maxH)
                maxH = screens[i].height
        }
        if (maxH > 0)
            config.maybeWritePreferred(maxH >= 2160 ? 2160 : 1080)
    }

    Connections {
        target: compositor
        function onBackendReadyChanged() {
            root.tryResolvePanel()
        }
        function onFocusedOutputNameChanged() {
            root.tryResolvePanel()
        }
    }

    WlSessionLock {
        id: sessionLock
        locked: root.locked

        WlSessionLockSurface {
            id: lockSurface
            color: config.data.backgroundColor

            // Video background (d32) — behind LockContent (first child
            // paints last-on-bottom). Never eager: active stays false when
            // no source is configured, so libmpv is not started for
            // nothing. This is resource isolation, not plugin-optionality:
            // qt6-mpvqml is required.
            Loader {
                id: bgLoader
                anchors.fill: parent
                active: root.hasBackground
                source: "LockBackground.qml"

                onLoaded: {
                    // LockBackground.applySource() runs on the items change;
                    // the list is final by the time the Loader activates.
                    item.items = root.bgItems
                    // qmllint disable missing-property
                    // Loader.item is typed QObject; the loaded item is
                    // LockBackground.qml, which defines the loadFailed
                    // signal — dynamic by design, qmllint cannot see it.
                    item.loadFailed.connect(function (message) {
                        root.logger.w("aerial-lock", "video background failed: " + message)
                    })
                    // qmllint enable missing-property
                }
                onStatusChanged: {
                    if (status === Loader.Error)
                        root.logger.w("aerial-lock", "video background unavailable — solid color")
                }
            }

            // Stop playback before shell.qml tears the lock tree down on
            // unlock (mpv render context out of the destruction path).
            Connections {
                target: root
                function onLockedChanged() {
                    // qmllint disable missing-property
                    // Same Loader.item dynamism — LockBackground.shutdown().
                    if (!root.locked && bgLoader.item)
                        bgLoader.item.shutdown()
                    // qmllint enable missing-property
                }
            }

            readonly property bool hostsPanel: {
                if (!Quickshell.screens || Quickshell.screens.length <= 1)
                    return true
                return lockSurface.screen
                       && lockSurface.screen.name === root.panelScreenName
            }

            // Video playback export for LockContext. These live INSIDE
            // the surface: ids are visible only in the subtree of their
            // declaring object, so bgLoader is unreachable from root.
            //
            // qmllint disable missing-property
            // bgLoader.item is typed QObject; the loaded item is
            // LockBackground.qml, which defines these — dynamic by design.
            Binding { target: lockContext.video; property: "position"; value: bgLoader.item ? bgLoader.item.position : 0 }
            Binding { target: lockContext.video; property: "duration"; value: bgLoader.item ? bgLoader.item.duration : 0 }
            Binding { target: lockContext.video; property: "hasVideo"; value: bgLoader.item ? bgLoader.item.hasVideo : false }
            Binding { target: lockContext.video; property: "path"; value: bgLoader.item ? bgLoader.item.currentFilename : "" }
            // qmllint enable missing-property

            // Coverage confirmation starts optional theme work; window
            // activation remains the separate keyboard-focus backstop.
            Connections {
                target: sessionLock
                function onSecureStateChanged() {
                    if (sessionLock.secure && lockSurface.hostsPanel) {
                        themeHost.focusInput()
                        lockSurface.publishThemeTopics()
                    }
                }
            }

            // d40: the theme's topic preference is known once its content
            // is loaded (fallback panel: none). Start the inventory then —
            // its snapshot is frozen per lock and gates the background.
            function publishThemeTopics() {
                if (!sessionLock.secure || !lockSurface.hostsPanel || !themeHost.settled || root.themeTopicsSet)
                    return
                root.themeTopicsSet = true
                sourceCache.topics = themeHost.preferredTopics
                sourceCache.begin()
            }

            onHostsPanelChanged: publishThemeTopics()

            Connections {
                target: themeHost
                function onReady() {
                    lockSurface.publishThemeTopics()
                }
            }

            // d40: the configured whole-surface theme (or the built-in
            // panel as ThemeHost's fallback) lives INSIDE the trusted
            // surface — untrusted QML is never the surface component.
            ThemeHost {
                id: themeHost
                anchors.fill: parent
                visible: lockSurface.hostsPanel
                enabled: lockSurface.hostsPanel
                focus: lockSurface.hostsPanel
                context: lockContext
                config: root.config
                logger: root.logger
                allowLoading: sessionLock.secure && root.locked && lockSurface.hostsPanel
                fallbackPinned: root.themeFallbackPinned
                onFallbackRequested: root.themeFallbackPinned = true
            }

            // Scenery-only backdrop export for themes that declare a
            // `backdrop` property. bgLoader's id is visible only in this
            // surface subtree, so the binding lives here. Null when the
            // video background is inactive — themes must tolerate that.
            Binding { target: themeHost; property: "backdrop"; value: bgLoader.item }
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
                if (acceptedResponse !== null) {
                    // Phase 1: the just-submitted response answers this
                    // prompt. Clear before respond so the property holds a
                    // value only across the async gap.
                    var response = acceptedResponse.text
                    acceptedResponse = null
                    pam.respond(response)
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
                acceptedResponse = null
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
            acceptedResponse = null
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
            acceptedResponse = null
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

    function tryUnlock() {
        logger.d("Lock", "tryUnlock: unlockInProgress=" + unlockInProgress +
            " pam.responseRequired=" + pam.responseRequired)
        if (unlockInProgress) {
            return
        }

        // Snapshot and consume the shared draft exactly once; the consume
        // invalidates stale view publications (all mirrors clear).
        var draft = lockContext.auth.input.consume()

        if (pam.responseRequired) {
            logger.d("Lock", "tryUnlock: calling pam.respond")
            acceptedResponse = null
            pam.respond(draft)
            unlockInProgress = true
            authState = authAuthenticating
            statusMessage = i18n.authenticating || "Authenticating..."
            watchdog.restart()
        } else {
            logger.d("Lock", "tryUnlock: calling pam.start")
            watchdog.restart()
            attemptCancelled = false
            // Reserve the response before the asynchronous first PAM prompt.
            unlockInProgress = true
            if (!pam.start()) {
                watchdog.stop()
                acceptedResponse = null
                unlockInProgress = false
                authState = authError
                statusMessage = i18n.authError || "Authentication error"
                logger.w("aerial-lock", "pam.start() failed for service " + pam.config)
            } else {
                // An empty initial submit starts PAM and exposes its prompt
                // WITHOUT queueing an empty first answer.
                acceptedResponse = draft.length > 0 ? ({ "text": draft }) : null
                authState = authAuthenticating
            }
        }
    }
}
