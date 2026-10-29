import QtQuick
import "../Services"
import "../Modules/Lock" as LockModule

// Trusted test theme: observes only its injected public context and AuthField
// interface. Never emits response text or credential-derived editor metadata.
FocusScope {
    id: root
    required property LockContext context
    property Item backdrop: null
    readonly property var preferredTopics: []
    property int captures: 0
    function focusInput() { field.focusField() }
    Component.onCompleted: console.log("REMEDIATION_THEME_CREATED")
    Component.onDestruction: console.log("REMEDIATION_THEME_DESTROYED")
    LockModule.FrostedText {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        scenery: root.backdrop
        text: "12:34"
        fontPixelSize: 64
    }
    LockModule.AuthField {
        id: field
        anchors.centerIn: parent
        width: 280
        context: root.context
        initialSpacePolicy: context.auth.input.policyIgnoreFirst
        initialSpaceScope: context.auth.input.scopeLock
    }
    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            var input = root.context.auth.input
            var snapshot = { output: root.context.session.outputName,
                focused: field.hasActiveFocus,
                windowActive: root.Window.active,
                attached: root.Window.window !== null,
                backdropSameWindow: root.backdrop !== null
                    && root.backdrop.Window.window === root.Window.window,
                hasVideo: root.context.video.hasVideo,
                position: root.context.video.position,
                syntheticDraft: input.text === "synthetic-failover-draft" }
            if (snapshot.syntheticDraft) {
                snapshot.cursor = input.cursorPosition
                snapshot.anchor = input.anchorPosition
                snapshot.revision = input.revision
                snapshot.writer = input.activeWriter
                snapshot.generation = input.generation
                snapshot.policy = input.effectivePolicy
                snapshot.scope = input.effectiveScope
                snapshot.latched = input.tuningLatched
                snapshot.initialWindowOpen = input.initialWindowOpen
                snapshot.composing = input.compositionActive
            }
            console.log("PANEL_SNAPSHOT " + JSON.stringify(snapshot))
        }
    }
}
