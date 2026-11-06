import QtQuick
import "../Services"
import "../Modules/Lock" as LockModule

// Credential-free observations end before password entry. Only our synthetic
// prefix is eligible for text/selection diagnostics, never fixture credentials.
FocusScope {
    id: root
    required property LockContext context
    property bool observing: true
    function focusInput() { field.focusField() }
    Component.onCompleted: console.log("SURFACE_THEME_CREATED")
    Component.onDestruction: console.log("SURFACE_THEME_DESTROYED")
    Keys.onPressed: function (event) {
        if (event.key === Qt.Key_F10) {
            root.observing = false
            root.context.auth.input.clear()
            console.log("SURFACE_OBSERVATION_STOPPED")
            event.accepted = true
        }
    }
    LockModule.AuthEditor {
        id: field
        anchors.centerIn: parent
        width: 300
        height: 40
        input: root.context.auth.input
        inputBusy: root.context.auth.inProgress
        responseVisible: root.observing || root.context.auth.responseVisible
        maxResponseSize: root.context.auth.maxResponseSize
        onSubmitRequested: root.context.auth.submit()
    }
    Timer {
        interval: 10
        repeat: true
        running: root.observing
        onTriggered: {
            if (!root.observing)
                return
            var model = root.context.auth.input
            var state = {output: root.context.session.outputName,
                windowActive: root.Window.active, focused: field.hasActiveFocus,
                composing: field.inputMethodComposing,
                activeComposing: model.compositionActive,
                writer: model.activeWriter, themeWriter: model.themeWriter,
                generation: model.generation, revision: model.revision}
            if (model.text.indexOf("sinks-") === 0) {
                state.syntheticText = model.text
                state.cursor = model.cursorPosition
                state.anchor = model.anchorPosition
            }
            console.log("SURFACE_STATE " + JSON.stringify(state))
        }
    }
}
