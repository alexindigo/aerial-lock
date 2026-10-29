import QtQuick
import Quickshell
import Quickshell.Io
import "../../Services"

// The trusted panel never waits for theme I/O. A candidate is quarantined
// until ready; failure or the loading deadline pins the fallback for the
// lock. d43: interaction no longer pins — a ready candidate takes over the
// SHARED draft via the context's writer handoff (flush the outgoing editor,
// invalidate stale publications, hydrate the incoming editor, then transfer
// focus/authority), so a promoted theme loses no characters and PAM is
// never restarted. The handoff defers while native composition or an edit
// gesture cannot safely transfer; the existing editor stays alive and
// focused until then (the native session is never force-committed).
Item {
    id: root

    required property LockContext context
    required property ConfigStore config
    required property Logger logger
    property Item backdrop: null
    property bool allowLoading: false
    property bool fallbackPinned: false

    signal ready()
    signal fallbackRequested()

    readonly property string activeThemePath: internal.selectedPath
    readonly property bool usingFallback: !internal.useTheme
    readonly property bool settled: internal.settled
    readonly property var preferredTopics: internal.topics

    // QObject ownership stays with Lock's Scope; only visual attachment moves.
    // Clear the old backdrop before crossing windows, including equal geometry.
    function attachTo(attachment, scenery) {
        if (root.parent === attachment) {
            root.backdrop = scenery || null
            return
        }
        root.backdrop = null
        root.parent = attachment
        root.backdrop = scenery || null
        if (attachment)
            Qt.callLater(root.focusInput)
    }

    QtObject {
        id: internal
        property bool complete: false
        property bool settled: false
        property bool useTheme: false
        property string phase: "waiting"
        property string name: ""
        property string selectedPath: ""
        property var topics: []
        // A candidate prepared successfully and is waiting for the shared
        // draft's handoff to complete before promotion.
        property bool handoffPending: false
    }

    function validThemeFilename(name) {
        return typeof name === "string" && name.length > 0 && name.length <= 255
            && name.slice(-4) === ".qml" && name.indexOf("/") === -1
            && name.indexOf("\\") === -1 && name.indexOf("..") === -1
            && name.indexOf(":") === -1
    }

    function settle(useTheme, topics) {
        if (internal.settled)
            return
        deadline.stop()
        handoffClaimGrace.stop()
        internal.useTheme = useTheme
        internal.topics = topics
        internal.settled = true
        if (!useTheme)
            root.fallbackRequested()
        root.logger.d("ThemeHost", "loaded " + (useTheme ? "theme " + internal.selectedPath : "fallback panel")
                      + " topics=" + JSON.stringify(topics))
        root.ready()
        Qt.callLater(root.focusInput)
    }

    function cancelPendingHandoff() {
        if (!internal.handoffPending)
            return
        internal.handoffPending = false
        handoffClaimGrace.stop()
        context.auth.input.abortHandoff()
    }

    function failSelected(reason) {
        if (internal.settled)
            return
        cancelPendingHandoff()
        root.logger.w("ThemeHost", "theme " + internal.selectedPath + " failed: " + reason
                      + " - using built-in panel")
        settle(false, [])
    }

    // The candidate's editor claimed the shared draft: promote.
    function promote() {
        if (internal.settled || !internal.handoffPending)
            return
        internal.handoffPending = false
        handoffClaimGrace.stop()
        var item = candidate.item
        if (!item) {
            failSelected("theme vanished during handoff")
            return
        }
        item.focus = true
        settle(true, internal.topics)
    }

    function begin() {
        if (!internal.complete || !allowLoading || internal.settled || internal.phase !== "waiting")
            return
        if (fallbackPinned) {
            settle(false, [])
            return
        }
        internal.name = config.data.theme
        internal.selectedPath = String(internal.name)
        if (!validThemeFilename(internal.name)) {
            failSelected("invalid filename")
            return
        }
        internal.phase = "user"
        internal.selectedPath = config.configDir + "/themes/" + internal.name
        deadline.start()
        userProbe.path = internal.selectedPath
    }

    function loadCandidate() {
        if (internal.settled || !allowLoading)
            return
        internal.phase = "candidate"
        // Bundled imports must share Quickshell's root URL/type identity.
        var url = internal.selectedPath.indexOf(Quickshell.shellDir + "/Themes/") === 0
                ? "root:/Themes/" + internal.name : "file://" + internal.selectedPath
        candidate.setSource(url, { "context": root.context })
    }

    function readTopics(item) {
        var topics = item.preferredTopics
        if (topics === undefined || topics === null)
            return []
        if (!Array.isArray(topics)) {
            root.logger.w("ThemeHost", "preferredTopics is not a list; treating as no preference")
            return []
        }
        var result = []
        for (var i = 0; i < topics.length; i++) {
            if (typeof topics[i] === "string")
                result.push(topics[i])
            else
                root.logger.w("ThemeHost", "preferredTopics[" + i + "] is not a string; dropped")
        }
        return result
    }

    // Separate one-shot probes: switching a FileView's path in its own
    // completion handler can overlap the finishing and replacement reads.
    FileView {
        id: userProbe
        blockLoading: false
        printErrors: false
        onLoaded: {
            if (internal.settled || internal.phase !== "user")
                return
            if (text().length === 0)
                root.failSelected("empty user override")
            else
                root.loadCandidate()
        }
        onLoadFailed: function (error) {
            if (internal.settled || internal.phase !== "user")
                return
            if (error !== FileViewError.FileNotFound) {
                root.failSelected("user override: " + FileViewError.toString(error))
                return
            }
            internal.phase = "bundled"
            internal.selectedPath = Quickshell.shellDir + "/Themes/" + internal.name
            bundledProbe.path = internal.selectedPath
        }
    }

    FileView {
        id: bundledProbe
        blockLoading: false
        printErrors: false
        onLoaded: {
            if (internal.settled || internal.phase !== "bundled")
                return
            if (text().length === 0)
                root.failSelected("empty bundled theme")
            else
                root.loadCandidate()
        }
        onLoadFailed: function (error) {
            if (!internal.settled && internal.phase === "bundled")
                root.failSelected("bundled theme: " + FileViewError.toString(error))
        }
    }

    Timer {
        id: deadline
        interval: 2000
        onTriggered: root.failSelected("loading deadline reached")
    }

    // Preparation succeeded but no editor claimed the shared draft (a theme
    // without the input core or a conforming custom input). Bounded: the
    // claim normally lands in the same event turn as the release. This is
    // NOT the loading deadline, which stopped at preparation success.
    Timer {
        id: handoffClaimGrace
        interval: 1000
        onTriggered: root.failSelected("theme editor did not claim the shared draft")
    }

    Connections {
        target: context.auth.input
        function onHandoffStateChanged() {
            if (internal.handoffPending && context.auth.input.handoffState === "awaitingClaim")
                handoffClaimGrace.restart()
        }
        function onHandoffCompleted() {
            root.promote()
        }
    }

    LockContent {
        id: baseline
        anchors.fill: parent
        context: root.context
        visible: !internal.useTheme
        enabled: visible
        focus: visible
    }

    Loader {
        id: candidate
        anchors.fill: parent
        asynchronous: true
        // Settlement owns candidate lifetime, including an incubation that
        // has not completed yet. A pinned fallback retains no hidden theme.
        active: !internal.settled || internal.useTheme
        visible: internal.useTheme
        enabled: visible
        focus: internal.useTheme
        onLoaded: {
            if (internal.settled || !root.allowLoading || root.fallbackPinned)
                return
            if (!(item instanceof Item)) {
                root.failSelected("root is not a visual Item")
                return
            }
            try {
                if (item.hasOwnProperty("backdrop"))
                    item.backdrop = Qt.binding(function () { return root.backdrop })
                internal.topics = root.readTopics(item)
                // Preparation succeeded: the loading deadline stops here.
                // Waiting for the user to finish an in-flight composition
                // during the handoff is not a loading timeout.
                deadline.stop()
                internal.handoffPending = true
                root.context.auth.input.requestHandoff()
            } catch (error) {
                root.failSelected("theme contract: " + error)
            }
        }
        onStatusChanged: {
            if (status === Loader.Error && !internal.settled)
                root.failSelected("load error")
        }
    }

    function focusInput() {
        if (!root.visible || !root.enabled)
            return
        if (!internal.useTheme) {
            baseline.focusInput()
            return
        }
        // qmllint disable missing-property
        // Loader.item exposes the optional theme focus method dynamically.
        var item = candidate.item
        if (!item)
            return
        try {
            if (typeof item.focusInput === "function")
                item.focusInput()
            else
                item.forceActiveFocus()
        } catch (error) {
            root.logger.w("ThemeHost", "focus hook failed: " + error)
            item.forceActiveFocus()
        }
        // qmllint enable missing-property
    }

    onAllowLoadingChanged: begin()
    onFallbackPinnedChanged: {
        if (fallbackPinned && !internal.settled) {
            cancelPendingHandoff()
            settle(false, [])
        }
    }
    Component.onCompleted: {
        internal.complete = true
        begin()
    }
}
