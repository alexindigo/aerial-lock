import QtQuick
import "../../Services" as Services

// A conforming custom candidate whose claim is driven by the test, so the
// host's release/claim deadlines can be observed independently of AuthField.
FocusScope {
    id: root
    required property Services.LockContext context
    readonly property var preferredTopics: []
    property int writerToken: -1
    readonly property string draft: context.auth.input.text

    function claim() {
        return context.auth.input.claimHandoff(writerToken)
    }
    function focusInput() {}

    Component.onCompleted: writerToken = context.auth.input.registerWriter()
}
