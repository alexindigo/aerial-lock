import QtQuick
import QtQuick.Controls
import Quickshell.Wayland

FocusScope {
    id: root

    required property QtObject config

    property string statusMessage: ""
    property bool unlockInProgress: false

    readonly property var configData: config.data || {}
    readonly property var i18n: config.i18n || {}
    readonly property var panel: configData.panel || {}
    readonly property var colors: configData.colors || {}
    readonly property int maxResponseSize: config.pamLimits ? config.pamLimits.maxResponseSize : 512

    signal passwordSubmitted(string password)
    signal dismissRequested()

    function log(t) { console.log("[" + Date.now() + "] LockContent:", t) }

    Component.onCompleted: {
        log("Component.onCompleted")
        passwordField.forceActiveFocus()
    }

    focus: true

    Rectangle {
        id: panelRect
        anchors.centerIn: parent
        width: Math.min(panel.widthMax || 360, root.width * 0.8)
        height: column.implicitHeight + (panel.outerMargin || 20) * 2
        radius: panel.radius || 12
        color: colors.panelFill || "#14ffffff"
        border.width: 1
        border.color: colors.panelBorder || "#1fffffff"

        Column {
            id: column
            anchors {
                left: parent.left
                right: parent.right
                verticalCenter: parent.verticalCenter
                margins: panel.outerMargin || 20
            }
            spacing: panel.spacing || 12

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.statusMessage
                color: root.statusMessage === (i18n.authFailed || "Authentication failed")
                    ? (colors.textError || "#ff5555")
                    : (colors.text || "#dddddd")
                font.pixelSize: panel.fontSize || 16
                horizontalAlignment: Text.AlignHCenter
            }

            Rectangle {
                id: fieldBorder
                anchors {
                    left: parent.left
                    right: parent.right
                }
                height: panel.fieldHeight || 40
                radius: panel.fieldRadius || 8
                color: colors.fieldFill || "#0fffffff"
                border.width: 1
                border.color: passwordField.activeFocus
                    ? (colors.fieldBorderFocused || "#40ffffff")
                    : (colors.fieldBorder || "#1affffff")

                TextInput {
                    id: passwordField
                    anchors {
                        fill: parent
                        margins: 12
                    }
                    verticalAlignment: TextInput.AlignVCenter
                    color: colors.input || "#ffffff"
                    font.pixelSize: panel.fontSize || 16
                    echoMode: TextInput.Password
                    passwordMaskDelay: 0
                    enabled: !root.unlockInProgress
                    focus: true
                    maximumLength: root.maxResponseSize

                    Keys.onPressed: function (event) {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            log("Enter pressed, len=" + text.length)
                            root.passwordSubmitted(text)
                            text = ""
                            event.accepted = true
                        }
                    }
                }
            }

            Rectangle {
                anchors {
                    left: parent.left
                    right: parent.right
                }
                height: panel.fieldHeight || 40
                radius: panel.fieldRadius || 8
                color: Qt.rgba(255, 80, 80, 0.15)
                border.width: 1
                border.color: Qt.rgba(255, 80, 80, 0.3)
                visible: configData.debugAllowDismiss || false

                Text {
                    anchors.centerIn: parent
                    text: i18n.dismissDebug || "Dismiss (debug)"
                    color: colors.textError || "#ff5555"
                    font.pixelSize: panel.fontSize || 16
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        log("dismiss button clicked")
                        root.dismissRequested()
                    }
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onPositionChanged: {
            if (!passwordField.activeFocus) {
                passwordField.forceActiveFocus()
            }
        }
    }

}
