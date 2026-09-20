import QtQuick
import QtQuick.Controls
import Quickshell.Wayland

FocusScope {
    id: root

    required property QtObject config
    required property QtObject logger
    required property bool isErrorState

    property string statusMessage: ""
    property bool unlockInProgress: false
    property bool responseVisible: false

    readonly property var configData: config.data || {}
    readonly property var i18n: config.i18n || {}
    readonly property var panel: configData.panel || {}
    readonly property var colors: configData.colors || {}
    readonly property int maxResponseSize: config.pamLimits.maxResponseSize

    signal passwordSubmitted(string password)
    signal dismissRequested()

    Component.onCompleted: {
        logger.d("LockContent", "Component.onCompleted")
        passwordField.forceActiveFocus()
    }

    // Re-arm focus whenever the field becomes usable again: a fresh PAM
    // prompt, a failed attempt, or a watchdog abort all land here.
    onUnlockInProgressChanged: {
        if (!unlockInProgress) {
            passwordField.forceActiveFocus()
        }
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
                color: root.isErrorState
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
                    echoMode: responseVisible ? TextInput.Normal : TextInput.Password
                    passwordMaskDelay: 0
                    enabled: !root.unlockInProgress
                    focus: true
                    // PAM_MAX_RESP_SIZE counts the NUL terminator, hence -1.
                    // 0 means the real limit is unknown: cap at SHRT_MAX, the
                    // widget's own ceiling — never at a guessed PAM value.
                    maximumLength: root.maxResponseSize > 0 ? root.maxResponseSize - 1 : 32767

                    Keys.onPressed: function (event) {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
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
                color: Qt.rgba(1, 0.31, 0.31, 0.15)
                border.width: 1
                border.color: Qt.rgba(1, 0.31, 0.31, 0.3)
                visible: config.buildFlags.debugAllowDismiss

                Text {
                    anchors.centerIn: parent
                    text: i18n.dismissDebug || "Dismiss (debug)"
                    color: colors.textError || "#ff5555"
                    font.pixelSize: panel.fontSize || 16
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        logger.d("LockContent", "dismiss button clicked")
                        root.dismissRequested()
                    }
                }
            }
        }
    }

}
