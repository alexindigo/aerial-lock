import QtQuick
import "../Services"
import "../Modules/Lock" as LockModule

// Test consumer of the production selected-background and auth contracts.
// Logs media/resource outcomes only; never observes or logs editable responses.
FocusScope {
    id: root
    required property LockContext context
    property Item backdrop: null
    readonly property var preferredTopics: []
    property string observedPath: ""
    property int trackTransitions: 0
    property int sensed: 0
    property bool previousSensed: false
    function focusInput() { field.focusField() }
    LockModule.AuthField {
        id: field
        anchors.centerIn: parent
        width: 280
        context: root.context
    }
    Timer {
        interval: 500
        repeat: true
        running: true
        onTriggered: {
            var video = root.context.video
            if (video.path.length > 0 && video.path !== root.observedPath) {
                root.observedPath = video.path
                root.trackTransitions++
            }
            var hasAccent = video.accent.a > 0.5
            if (hasAccent && !root.previousSensed) root.sensed++
            root.previousSensed = hasAccent
            console.log("RESOURCE_MEDIA " + JSON.stringify({
                path: video.path, position: video.position, duration: video.duration,
                hasVideo: video.hasVideo, accentReady: hasAccent,
                transitions: root.trackTransitions, sensed: root.sensed,
                focused: field.hasActiveFocus, output: root.context.session.outputName }))
        }
    }
}
