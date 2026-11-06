pragma ComponentBehavior: Bound
import QtQuick
import "../Services" as Services
import "../Modules/Lock" as LockModule

// Credential-free native fixture: actual editors, no carrier or IME daemon.
Item {
    id: root
    readonly property Services.AuthInputState draft: model
    property var panel: null
    property var sink: null
    Services.AuthInputState { id: model }
    Component {
        id: panelComponent
        LockModule.AuthEditor {
            input: root.draft
            width: 280
            height: 40
            responseVisible: true
        }
    }
    Component {
        id: sinkComponent
        LockModule.AuthInputSink {
            input: root.draft
            responseVisible: true
        }
    }
    function newPanel(attachment) { panel = panelComponent.createObject(attachment) }
    function newSink(attachment) { sink = sinkComponent.createObject(attachment) }
    function attachPanel(attachment) {
        sink.panelAttached = true
        newPanel(attachment)
    }
}
