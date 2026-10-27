import QtQuick
import Qt5Compat.GraphicalEffects
import "../Services"
import "../Modules/Lock" as LockModule

// Windows7 (d44) — faithful adaptation of the qylock windows_7 reference
// (Darkkal44/qylock @ f6561e2, GPLv3; see Themes/ATTRIBUTION.md) over
// Aerial's video: centered login column at the reference −10s offset with
// the rounded-square glass avatar frame, name and Locked label, the compact
// field with its attached glossy arrow, Switch User beneath, and the full
// 52s bottom bar (session left, time/date center, power right).
//
// Intentional deviations (d44 plan): native AuthField masking instead of
// the reference's transparent editor + separate dot row; the session's own
// avatar via the shared Avatar (never the reference's bundled picture); the
// system-action controls are visible but unavailable (backend is a TODO —
// ~/Documents/Aerial/TODO.md:132-146); no entrance fade (input is never
// delayed); status renders genuine PAM prompts/errors and grows when
// wrapping. Narrow/portrait (d44 §9.1, compact stacking): the column
// already stacks vertically; the field and footer clamp to the surface.
FocusScope {
    id: root

    required property LockContext context
    property Item backdrop: null

    focus: true

    readonly property real s: Math.max(1, height) / 768
    readonly property string uiFont: "Segoe UI, Ubuntu, sans-serif"

    function focusInput() { field.focusField() }

    // Reference's boot vignette over the (possibly video) background.
    RadialGradient {
        anchors.fill: parent
        opacity: 0.35
        gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 1.0; color: "#1a0d1a30" }
        }
    }

    // One hover notice for every unavailable control; never interactive.
    property string hoverNotice: ""
    Text {
        id: noticeLabel
        objectName: "noticeLabel"
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: bottomBar.top
        anchors.bottomMargin: 12 * root.s
        visible: root.hoverNotice.length > 0
        text: root.hoverNotice
        font.pixelSize: 12 * root.s
        color: "#c8dce8"
        style: Text.Raised
        styleColor: "#60000000"
    }

    // ---- Centered login column ----
    Column {
        id: loginPanel
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -10 * root.s
        spacing: 0

        // Rounded-square glass avatar frame (reference: 132s, radius 18s).
        Item {
            id: pfpFrame
            objectName: "pfpFrame"
            width: 132 * root.s
            height: 132 * root.s
            anchors.horizontalCenter: parent.horizontalCenter

            Rectangle {
                anchors.fill: parent
                radius: 18 * root.s
                color: "transparent"
                border.color: "#99d0e8f8"
                border.width: 2 * root.s
                layer.enabled: true
                layer.effect: DropShadow {
                    transparentBorder: true
                    horizontalOffset: 0
                    verticalOffset: 2
                    radius: 16 * root.s
                    samples: 24
                    color: "#70000000"
                }
            }
            Rectangle {
                id: glassFrame
                anchors.fill: parent
                anchors.margins: 2 * root.s
                radius: 16 * root.s
                gradient: Gradient {
                    GradientStop { position: 0.00; color: "#e0f8ffff" }
                    GradientStop { position: 0.20; color: "#99b8ddf0" }
                    GradientStop { position: 0.50; color: "#446090b8" }
                    GradientStop { position: 0.85; color: "#993a7aaa" }
                    GradientStop { position: 1.00; color: "#e05090c0" }
                }
                // The session's own avatar, square-cropped per the
                // reference's 8s-radius image crop at 5s margins.
                LockModule.Avatar {
                    anchors.fill: parent
                    anchors.margins: 5 * root.s
                    diameter: width
                    cornerRadius: 8 * root.s
                    source: root.context.session.avatarPath
                    loginName: root.context.session.loginName
                    fallbackFill: "#40608a88"
                    foreground: "#f0f8ff"
                }
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 5 * root.s
                    radius: 12 * root.s
                    color: "transparent"
                    border.color: "#40000000"
                    border.width: 1 * root.s
                    z: 10
                }
                Rectangle {
                    anchors.top: parent.top
                    anchors.topMargin: 2 * root.s
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width - 12 * root.s
                    height: parent.height * 0.45
                    radius: 12 * root.s
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "#70ffffff" }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                    z: 15
                }
            }
        }

        Item { width: 1; height: 18 * root.s }

        Text {
            id: userNameText
            objectName: "userName"
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.context.session.loginName
            font.family: root.uiFont
            font.pixelSize: 26 * root.s
            color: "white"
            style: Text.Raised
            styleColor: "#40000000"
        }

        Item { width: 1; height: 4 * root.s }

        Text {
            id: lockedLabel
            objectName: "lockedLabel"
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Locked"
            font.family: root.uiFont
            font.pixelSize: 14 * root.s
            color: "#c8dce8"
            style: Text.Raised
            styleColor: "#40000000"
        }

        Item { width: 1; height: 14 * root.s }

        // The FIELD is centered; the arrow attaches 8s beyond its right
        // edge (the combined group is NOT centered).
        Item {
            id: passwordRow
            anchors.horizontalCenter: parent.horizontalCenter
            width: fieldFrame.width
            height: 28 * root.s

            Rectangle {
                id: fieldFrame
                objectName: "fieldFrame"
                anchors.centerIn: parent
                width: Math.min(240 * root.s, root.width - 60 * root.s)
                height: 28 * root.s
                radius: 2 * root.s
                color: "#f8fdff"
                border.color: field.hasActiveFocus ? "#3c7fb1" : "#40708898"
                border.width: 1 * root.s

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1 * root.s
                    radius: 1 * root.s
                    color: "transparent"
                    border.color: "#15000000"
                    border.width: 1 * root.s
                }

                // Placeholder lives outside the core, driven by the shared
                // draft's emptiness; it never hides a real PAM status.
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: 6 * root.s
                    text: "Password"
                    font.family: root.uiFont
                    font.pixelSize: 13 * root.s
                    color: "#80404050"
                    opacity: root.context.auth.input.text.length === 0 ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.InOutSine } }
                }

                LockModule.AuthField {
                    id: field
                    anchors { fill: parent; leftMargin: 6 * root.s; rightMargin: 6 * root.s }
                    context: root.context
                    textColor: "#101820"
                    fontFamily: root.uiFont
                    fontPixelSize: 13 * root.s
                }
            }

            // Glossy submit arrow, attached to the field's right edge.
            Item {
                id: arrowBtn
                objectName: "submitArrow"
                anchors.left: fieldFrame.right
                anchors.leftMargin: 8 * root.s
                anchors.verticalCenter: fieldFrame.verticalCenter
                width: 28 * root.s
                height: 28 * root.s
                enabled: !root.context.auth.inProgress
                opacity: enabled ? 1.0 : 0.5
                scale: arrowMouse.pressed ? 0.92 : (arrowMouse.containsMouse && enabled ? 1.08 : 1.0)
                Behavior on scale { NumberAnimation { duration: 100 } }

                Rectangle {
                    anchors.fill: parent
                    radius: 14 * root.s
                    color: "transparent"
                    border.color: arrowMouse.containsMouse ? "#80b0ccee" : "#40708898"
                    border.width: 1 * root.s
                }
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1 * root.s
                    radius: 13 * root.s
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: arrowMouse.containsMouse ? "#88c8e0ff" : "#60a0c4e8" }
                        GradientStop { position: 0.5; color: arrowMouse.containsMouse ? "#666090b4" : "#404870a0" }
                        GradientStop { position: 1.0; color: arrowMouse.containsMouse ? "#886090b8" : "#505888b0" }
                    }
                }
                Rectangle {
                    anchors.top: parent.top
                    anchors.topMargin: 2 * root.s
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width - 8 * root.s
                    height: 11 * root.s
                    radius: 7 * root.s
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "#45ffffff" }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                    z: 2
                }
                Canvas {
                    anchors.fill: parent
                    anchors.margins: 6 * root.s
                    z: 5
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.reset()
                        ctx.strokeStyle = "white"
                        ctx.lineWidth = 2.2 * root.s
                        ctx.lineCap = "round"
                        ctx.lineJoin = "round"
                        ctx.beginPath()
                        ctx.moveTo(2, height / 2)
                        ctx.lineTo(width - 2, height / 2)
                        ctx.moveTo(width - 6, height / 2 - 4)
                        ctx.lineTo(width - 2, height / 2)
                        ctx.lineTo(width - 6, height / 2 + 4)
                        ctx.stroke()
                    }
                }
                // MouseAreas never take keyboard focus: a pointer press
                // cannot steal the editor's focus mid-composition.
                MouseArea {
                    id: arrowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: field.submit()
                }
                Accessible.role: Accessible.Button
                Accessible.name: "Submit password"
            }
        }

        Item { width: 1; height: 8 * root.s }

        // Reserved status region: genuine PAM prompts/errors, wrapping and
        // growing instead of clipping instructions.
        Text {
            id: statusText
            objectName: "statusText"
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(318 * root.s, root.width - 60 * root.s)
            height: Math.max(implicitHeight, 15 * root.s)
            verticalAlignment: Text.AlignTop
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: text.length > 0
            text: root.context.auth.status
            font.family: root.uiFont
            font.pixelSize: 12 * root.s
            color: root.context.auth.isError ? "#ffddaa" : "#dce8f0"
            style: Text.Raised
            styleColor: "#60000000"
        }

        Item { width: 1; height: 20 * root.s }

        // Unavailable until the system-actions API lands (follow-up TODO).
        Item {
            id: switchUserBtn
            objectName: "switchUser"
            anchors.horizontalCenter: parent.horizontalCenter
            width: switchUserText.implicitWidth + 36
            height: 26 * root.s
            opacity: 0.55

            Rectangle {
                anchors.fill: parent
                radius: 3 * root.s
                color: "transparent"
                border.color: "#40708898"
                border.width: 1 * root.s
            }
            Rectangle {
                anchors.fill: parent
                anchors.margins: 1 * root.s
                radius: 2 * root.s
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#60a0c4e8" }
                    GradientStop { position: 0.5; color: "#404870a0" }
                    GradientStop { position: 1.0; color: "#505888b0" }
                }
            }
            Text {
                id: switchUserText
                anchors.centerIn: parent
                text: "Switch User"
                font.family: root.uiFont
                font.pixelSize: 13 * root.s
                color: "white"
                style: Text.Raised
                styleColor: "#30000000"
            }
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.hoverNotice = "Switching users is not implemented yet"
                onExited: root.hoverNotice = ""
            }
            Accessible.role: Accessible.Button
            Accessible.name: "Switch User (unavailable: system actions are not yet implemented)"
        }
    }

    // ---- Footer bar ----
    Item {
        id: bottomBar
        objectName: "footerBar"
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        // Compact stacking (d44 §9.1): below the width where the three
        // reference groups fit without overlap, the bar grows a second row —
        // session/power on top, the centered time/date below. Nothing is
        // hidden.
        readonly property bool narrow: root.width < sessionRow.implicitWidth
                + clockRow.implicitWidth + powerRow.implicitWidth + 60 * root.s
        height: narrow ? 82 * root.s : 52 * root.s

        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#28000010" }
                GradientStop { position: 1.0; color: "#60001030" }
            }
        }
        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1 * root.s
            color: "#30a0c8e0"
        }

        // Left: session affordance (unavailable).
        Row {
            id: sessionRow
            objectName: "sessionRow"
            anchors.left: parent.left
            anchors.leftMargin: 20 * root.s
            anchors.top: parent.top
            height: 52 * root.s
            spacing: 12 * root.s

            Text {
                text: "Session:"
                font.family: root.uiFont
                font.pixelSize: 12 * root.s
                color: "#c0d8e8"
                anchors.verticalCenter: parent.verticalCenter
            }
            Item {
                width: sessionPillText.implicitWidth + 24
                height: 24 * root.s
                anchors.verticalCenter: parent.verticalCenter
                opacity: 0.55
                Rectangle {
                    anchors.fill: parent
                    radius: 3 * root.s
                    color: "transparent"
                    border.color: "#40607888"
                    border.width: 1 * root.s
                }
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 1 * root.s
                    radius: 2 * root.s
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "#60a0c4e8" }
                        GradientStop { position: 0.5; color: "#404870a0" }
                        GradientStop { position: 1.0; color: "#505888b0" }
                    }
                }
                Text {
                    id: sessionPillText
                    anchors.centerIn: parent
                    // The current session; there is no selector backend.
                    text: "Session"
                    font.family: root.uiFont
                    font.pixelSize: 12 * root.s
                    color: "white"
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: root.hoverNotice = "Session selection is not implemented yet"
                    onExited: root.hoverNotice = ""
                }
            }
        }

        // Center: time / separator / date, from the shared clock.
        Row {
            id: clockRow
            objectName: "clockRow"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            spacing: 12 * root.s

            Text {
                text: Qt.formatTime(root.context.clock.now, "h:mm AP")
                font.family: root.uiFont
                font.pixelSize: 18 * root.s
                font.weight: Font.DemiBold
                color: "white"
                style: Text.Raised
                styleColor: "#80000000"
                anchors.verticalCenter: parent.verticalCenter
            }
            Item {
                width: 2 * root.s
                height: 18 * root.s
                anchors.verticalCenter: parent.verticalCenter
                Rectangle { anchors.left: parent.left; width: 1 * root.s; height: parent.height; color: "#40000000" }
                Rectangle { anchors.right: parent.right; width: 1 * root.s; height: parent.height; color: "#40ffffff" }
            }
            Text {
                text: Qt.formatDate(root.context.clock.now, "dddd, MMMM d")
                font.family: root.uiFont
                font.pixelSize: 14 * root.s
                color: "#e0f0ff"
                style: Text.Raised
                styleColor: "#80000000"
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        // Right: power actions (unavailable), Restart then Shut down.
        Row {
            id: powerRow
            objectName: "powerRow"
            anchors.right: parent.right
            anchors.rightMargin: 20 * root.s
            anchors.top: parent.top
            height: 52 * root.s
            spacing: 8 * root.s

            Win7GlassButton { label: "Restart"; notice: "Restart is not implemented yet"; anchors.verticalCenter: parent.verticalCenter }
            Win7GlassButton { label: "Shut down"; notice: "Shut down is not implemented yet"; anchors.verticalCenter: parent.verticalCenter }
        }

        states: State {
            name: "narrow"
            when: bottomBar.narrow
            AnchorChanges {
                target: clockRow
                anchors.verticalCenter: undefined
                anchors.bottom: bottomBar.bottom
            }
        }
    }

    // Nonblocking failure motion: the reference's shake on the column's
    // vertical offset; it always returns to the −10s resting position.
    Connections {
        target: root.context.auth
        function onIsErrorChanged() {
            if (root.context.auth.isError)
                shakeAnim.start()
        }
    }
    SequentialAnimation {
        id: shakeAnim
        NumberAnimation { target: loginPanel; property: "anchors.verticalCenterOffset"; to: -20 * root.s; duration: 50 }
        NumberAnimation { target: loginPanel; property: "anchors.verticalCenterOffset"; to: 0; duration: 50 }
        NumberAnimation { target: loginPanel; property: "anchors.verticalCenterOffset"; to: -15 * root.s; duration: 50 }
        NumberAnimation { target: loginPanel; property: "anchors.verticalCenterOffset"; to: -5 * root.s; duration: 50 }
        NumberAnimation { target: loginPanel; property: "anchors.verticalCenterOffset"; to: -10 * root.s; duration: 50 }
    }

    // Reference-style glass button, used only for the unavailable footer
    // power actions (a private inline style component, not a dispatcher).
    component Win7GlassButton: Item {
        property string label: ""
        property string notice: ""
        width: pwText.implicitWidth + 24
        height: 26 * root.s
        opacity: 0.55
        Rectangle {
            anchors.fill: parent
            radius: 3 * root.s
            color: "transparent"
            border.color: "#40708898"
            border.width: 1 * root.s
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: 1 * root.s
            radius: 2 * root.s
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#60a0c4e8" }
                GradientStop { position: 0.5; color: "#404870a0" }
                GradientStop { position: 1.0; color: "#505888b0" }
            }
        }
        Rectangle {
            anchors.top: parent.top
            anchors.topMargin: 1 * root.s
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 2 * root.s
            height: 9 * root.s
            radius: 3 * root.s
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#40ffffff" }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }
        Text {
            id: pwText
            anchors.centerIn: parent
            text: parent.label
            font.family: root.uiFont
            font.pixelSize: 13 * root.s
            color: "white"
        }
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onEntered: root.hoverNotice = notice
            onExited: root.hoverNotice = ""
        }
        Accessible.role: Accessible.Button
        Accessible.name: label + " (unavailable: system actions are not yet implemented)"
    }
}
