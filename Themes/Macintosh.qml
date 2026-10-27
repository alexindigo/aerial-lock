import QtQuick
import "../Services"
import "../Modules/Lock" as LockModule

// Macintosh (d40) — the default whole-surface theme, modern macOS
// composition over Aerial's video: centered long date above a very large
// frosted clock near the top; login name, compact field and status near the
// bottom (d45: no avatar — user-directed removal). Shared columns/anchors
// carry the alignment — no fixed panel offsets; sizes clamp to the
// available surface.
//
// The digits are translucent: blurred scenery inside crisp glyph
// silhouettes (FrostedText over the surface-local backdrop); outside
// scenery stays sharp. With no backdrop, digits fall back to readable
// tinted text.
FocusScope {
    id: root

    required property LockContext context
    property Item backdrop: null

    focus: true

    function focusInput() { field.focusField() }

    readonly property real vmin: Math.max(1, Math.min(width, height))

    // Date above the clock, both centered on the surface's vertical axis.
    LockModule.FrostedText {
        id: dateText
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: Math.round(root.height * 0.10)
        scenery: root.backdrop
        text: Qt.formatDate(root.context.clock.now, "dddd, MMMM d")
        fontPixelSize: Math.round(Math.min(root.vmin * 0.034, 36))
        fontBold: false
        blurRadius: 12
        padding: 12
    }

    LockModule.FrostedText {
        id: clockText
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: dateText.bottom
        anchors.topMargin: Math.round(root.height * 0.012)
        scenery: root.backdrop
        text: Qt.formatTime(root.context.clock.now, "hh:mm")
        fontPixelSize: Math.round(Math.min(root.vmin * 0.20, 240))
        fontBold: true
        blurRadius: 24
        padding: 28
    }

    // Bottom cluster: name, compact field, status — one centered column;
    // every row shares the column's centerline. (d45: no avatar — the
    // userpic read poorly; user-directed removal.)
    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Math.round(root.height * 0.08)
        spacing: Math.round(root.vmin * 0.016)

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: text.length > 0
            text: root.context.session.loginName
            color: root.context.colors.text
            font.pixelSize: Math.round(Math.min(root.vmin * 0.026, 26))
        }

        // Field frame (theme-owned decoration) around the shared core.
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.round(Math.min(root.width * 0.5, 280))
            height: root.context.panel.fieldHeight
            radius: root.context.panel.fieldRadius
            color: root.context.colors.fieldFill
            border.width: 1
            border.color: field.hasActiveFocus
                ? root.context.colors.fieldBorderFocused
                : root.context.colors.fieldBorder

            LockModule.AuthField {
                id: field
                anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                context: root.context
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(root.width * 0.8, 420)
            visible: text.length > 0
            text: root.context.auth.status
            color: root.context.auth.isError
                ? root.context.colors.textError
                : root.context.colors.text
            font.pixelSize: Math.round(Math.min(root.vmin * 0.02, 18))
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
        }
    }
}
