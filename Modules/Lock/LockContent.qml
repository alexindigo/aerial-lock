import QtQuick
import "../../Services"

// LockContent — the built-in baseline panel and the trusted ThemeHost
// fallback. Reads the one context object (the same contract a theme gets)
// — no ConfigStore, no Logger, no PAM knowledge (d38/d40).
//
// Plain Item root, NOT a FocusScope: with a scope here the window's
// focus delegation stopped at the panel instead of reaching the field
// (d40 flake — focusItem was LockContent, field never focused).
//
// d43: the shared AuthField core draws nothing; this panel owns the
// field's frame (fill/border/radius/height/padding) around it.
Item {
    id: root

    required property LockContext context

    readonly property var panel: context.panel
    readonly property var colors: context.colors
    readonly property var labels: context.labels

    focus: true

    // ThemeHost.focusInput() backstop target: aim at the field.
    function focusInput() { authField.focusField() }

    Rectangle {
        id: panelRect
        anchors.centerIn: parent
        width: Math.min(panel.widthMax, root.width * 0.8)
        height: column.implicitHeight + panel.outerMargin * 2
        radius: panel.radius
        color: colors.panelFill
        border.width: 1
        border.color: colors.panelBorder

        Column {
            id: column
            anchors {
                left: parent.left
                right: parent.right
                verticalCenter: parent.verticalCenter
                margins: panel.outerMargin
            }
            spacing: panel.spacing

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width
                wrapMode: Text.Wrap
                text: root.context.auth.status
                color: root.context.auth.isError
                    ? colors.textError
                    : colors.text
                font.pixelSize: panel.fontSize
                horizontalAlignment: Text.AlignHCenter
            }

            // The fallback's own field decoration around the shared core.
            Rectangle {
                anchors {
                    left: parent.left
                    right: parent.right
                }
                height: panel.fieldHeight
                radius: panel.fieldRadius
                color: colors.fieldFill
                border.width: 1
                border.color: authField.hasActiveFocus
                    ? colors.fieldBorderFocused
                    : colors.fieldBorder

                AuthField {
                    id: authField
                    anchors {
                        fill: parent
                        leftMargin: 12
                        rightMargin: 12
                    }
                    context: root.context
                }
            }

            Rectangle {
                anchors {
                    left: parent.left
                    right: parent.right
                }
                height: panel.fieldHeight
                radius: panel.fieldRadius
                color: Qt.rgba(1, 0.31, 0.31, 0.15)
                border.width: 1
                border.color: Qt.rgba(1, 0.31, 0.31, 0.3)
                visible: root.context.auth.dismissAvailable

                Text {
                    anchors.centerIn: parent
                    text: labels.dismissDebug
                    color: colors.textError
                    font.pixelSize: panel.fontSize
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: root.context.auth.dismiss()
                }
            }
        }
    }
}
