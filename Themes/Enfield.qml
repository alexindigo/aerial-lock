import QtQuick
import Qt5Compat.GraphicalEffects
import "../Services"
import "../Modules/Lock" as LockModule
import "../Modules/Lock/AccentTone.js" as AccentTone

// Enfield (d44) — faithful adaptation of the qylock enfield reference
// (Darkkal44/qylock @ f6561e2, GPLv3; see Themes/ATTRIBUTION.md) over
// Aerial's video: horizontal Orbitron clock + pulsing date dot top-left,
// the standalone bottom-centered auth column (tracked username, line-dot
// divider, translucent password pill with pink indicator, native ✦ mask
// and glowing pink ✦ caret, inset submit arrow), the footer separator with
// session/power affordances, and the drifting petals. Keeps the mountain
// topic preference.
//
// Intentional deviations (d44 plan): the reference's dark base gradient is
// replaced by the lock's own background (the video or solid color shows
// through); the vignette/mist/tint/petals stay; the username and footer
// affordances are visible but unavailable (system actions are a follow-up
// TODO); native AuthField masking/caret instead of the reference's NoEcho
// editor + manual star row; no entrance fade (input is never delayed);
// decorative animations stop when the surface is not shown. Compact
// stacking (d44 §9.1): the column already stacks vertically; field width
// clamps to the surface.
FocusScope {
    id: root

    required property LockContext context
    property Item backdrop: null

    // Keep Enfield's topic preference.
    readonly property var preferredTopics: ["mountain", "mountains"]

    focus: true

    readonly property real s: Math.max(1, height) / 768

    FontLoader {
        id: orbitron
        source: "fonts/orbitron/Orbitron-VariableFont_wght.ttf"
    }
    readonly property string uiFont: orbitron.name !== "" ? orbitron.name : "sans-serif"

    // d45: the sakura accent tier follows the video's sensed accent color
    // (user-directed: not always red). Lightness relations are preserved;
    // unsensed → the static sakura palette below. mistWhite and the error
    // color stay static; petals and the rose atmosphere tint follow the hue.
    readonly property color seed: root.context.video.accent
    readonly property bool seeded: seed.a > 0

    function tone(baseHex) {
        return AccentTone.tone(baseHex, seed.hslHue, seed.hslSaturation)
    }

    readonly property color sakuraPink: seeded ? tone("#d4849e") : "#d4849e"
    readonly property color sakuraLight: seeded ? tone("#f0c4d4") : "#f0c4d4"
    readonly property color mistWhite: "#e8eef2"

    function focusInput() { field.focusField() }

    // ---- Atmosphere over the video ----
    RadialGradient {
        anchors.fill: parent
        opacity: 0.6
        gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 1.0; color: "#c0000000" }
        }
    }
    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 260 * root.s
        opacity: 0.55
        gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 1.0; color: "#e8000000" }
        }
    }
    Rectangle {
        anchors.fill: parent
        // Rose atmosphere tint; hue follows the video accent when seeded.
        color: root.seeded ? Qt.hsla(root.seed.hslHue, 0.55, 0.45, 0.031) : "#08c86080"
        opacity: 0.5
    }

    // The reference's finite 18-petal population. No input interception;
    // animations run only while the surface is shown.
    Repeater {
        model: 18
        delegate: Item {
            id: petal
            property real startX: Math.random() * root.width
            property real drift: (Math.random() - 0.5) * 120
            property real dur: 7000 + Math.random() * 8000
            property real sz: 4 + Math.random() * 6
            property real delayMs: Math.random() * 8000
            property real rot: Math.random() * 360

            x: startX
            y: -20 * root.s
            width: sz
            height: sz * 0.6
            opacity: 0

            Rectangle {
                anchors.fill: parent
                radius: width * 0.5
                // Petals jitter around the accent hue (sakura pink when
                // unseeded) instead of a fixed pink random box.
                property real hue: (root.sakuraPink.hslHue + (Math.random() - 0.5) * 0.06 + 1) % 1
                color: Qt.hsla(hue, 0.5 + Math.random() * 0.2,
                               0.68 + Math.random() * 0.12, 0.7)
                rotation: petal.rot
            }

            SequentialAnimation {
                running: root.visible
                loops: Animation.Infinite
                PauseAnimation { duration: petal.delayMs }
                ParallelAnimation {
                    NumberAnimation {
                        target: petal; property: "y"
                        from: -20; to: root.height + 20
                        duration: petal.dur; easing.type: Easing.InOutSine
                    }
                    NumberAnimation {
                        target: petal; property: "x"
                        from: petal.startX; to: petal.startX + petal.drift
                        duration: petal.dur; easing.type: Easing.InOutSine
                    }
                    SequentialAnimation {
                        NumberAnimation { target: petal; property: "opacity"; to: 0.75; duration: 800 }
                        PauseAnimation { duration: petal.dur - 1600 }
                        NumberAnimation { target: petal; property: "opacity"; to: 0; duration: 800 }
                    }
                    NumberAnimation {
                        target: petal; property: "rotation"
                        from: petal.rot; to: petal.rot + 540
                        duration: petal.dur
                    }
                }
            }
        }
    }

    // ---- Clock block (top-left) ----
    Column {
        id: clockCol
        objectName: "clockCol"
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.leftMargin: 64 * root.s
        anchors.topMargin: 55 * root.s
        spacing: 6 * root.s

        Text {
            text: Qt.formatTime(root.context.clock.now, "HH:mm")
            color: root.mistWhite
            font.family: root.uiFont
            font.pixelSize: 80 * root.s
            font.weight: Font.Light
        }

        Row {
            spacing: 12 * root.s
            Rectangle {
                width: 6 * root.s
                height: 6 * root.s
                radius: 3 * root.s
                color: root.sakuraPink
                anchors.verticalCenter: parent.verticalCenter
                SequentialAnimation on opacity {
                    loops: Animation.Infinite
                    running: root.visible
                    NumberAnimation { to: 0.3; duration: 1800; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1.0; duration: 1800; easing.type: Easing.InOutSine }
                }
            }
            Text {
                text: Qt.formatDate(root.context.clock.now, "dddd, MMMM d").toUpperCase()
                color: root.sakuraPink
                font.family: root.uiFont
                font.pixelSize: 12 * root.s
                font.letterSpacing: 3 * root.s
                font.weight: Font.Light
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    // ---- Bottom-centered authentication column ----
    Column {
        id: loginPanel
        objectName: "authColumn"
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 110 * root.s
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(360 * root.s, root.width - 80 * root.s)
        spacing: 0
        transform: Translate { id: shakeShift }

        Text {
            id: userNameText
            objectName: "userName"
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.context.session.loginName
            color: root.mistWhite
            font.family: root.uiFont
            font.pixelSize: 18 * root.s
            font.weight: Font.Light
            font.letterSpacing: 4 * root.s
            opacity: 0.75

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.hoverNotice = "Switching users is not implemented yet"
                onExited: root.hoverNotice = ""
            }
            Accessible.role: Accessible.Button
            Accessible.name: "User " + root.context.session.loginName + " (switching unavailable: system actions are not yet implemented)"
        }

        Item { width: 1; height: 6 * root.s }

        // line-dot-line divider
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 8 * root.s
            Rectangle { width: 40 * root.s; height: 1 * root.s; color: root.sakuraPink; opacity: 0.5; anchors.verticalCenter: parent.verticalCenter }
            Rectangle { width: 5 * root.s; height: 5 * root.s; radius: 2.5 * root.s; color: root.sakuraPink; opacity: 0.8 }
            Rectangle { width: 40 * root.s; height: 1 * root.s; color: root.sakuraPink; opacity: 0.5; anchors.verticalCenter: parent.verticalCenter }
        }

        Item { width: 1; height: 22 * root.s }

        // Standalone translucent password pill.
        Item {
            id: fieldPill
            objectName: "fieldPill"
            width: parent.width
            height: 48 * root.s
            anchors.horizontalCenter: parent.horizontalCenter

            Rectangle {
                anchors.fill: parent
                radius: 24 * root.s
                color: Qt.rgba(1, 1, 1, field.hasActiveFocus ? 0.10 : 0.06)
                border.color: field.hasActiveFocus
                              ? Qt.rgba(root.sakuraPink.r, root.sakuraPink.g, root.sakuraPink.b, 0.6)
                              : Qt.rgba(1, 1, 1, 0.10)
                border.width: 1 * root.s
                Behavior on border.color { ColorAnimation { duration: 300 } }
                Behavior on color { ColorAnimation { duration: 300 } }
            }

            // Leading pink indicator.
            Rectangle {
                anchors.left: parent.left
                anchors.leftMargin: 18 * root.s
                anchors.verticalCenter: parent.verticalCenter
                width: 6 * root.s
                height: 6 * root.s
                radius: 3 * root.s
                color: root.sakuraPink
                opacity: field.hasActiveFocus ? 1.0 : 0.2
                Behavior on opacity { NumberAnimation { duration: 300 } }
            }

            // Placeholder outside the core, driven by shared-draft emptiness.
            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: 36 * root.s
                visible: root.context.auth.input.text.length === 0
                         && root.context.auth.status.length === 0
                text: "password"
                color: "white"
                opacity: 0.2
                font.family: root.uiFont
                font.pixelSize: 13 * root.s
                font.letterSpacing: 2 * root.s
                Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.InOutSine } }
            }

            LockModule.AuthField {
                id: field
                objectName: "field"
                anchors {
                    left: parent.left
                    leftMargin: 36 * root.s
                    right: submitBtn.left
                    rightMargin: 10 * root.s
                    verticalCenter: parent.verticalCenter
                }
                context: root.context
                textColor: "white"
                fontFamily: root.uiFont
                fontPixelSize: 13 * root.s
                fontLetterSpacing: 8 * root.s
                maskCharacter: "✦"
                selectionColor: root.sakuraPink
                // The pink glowing star caret: draw-only; the native editor
                // positions it.
                cursorDelegate: Component {
                    Text {
                        id: caret
                        text: "✦"
                        color: root.sakuraPink
                        font.family: root.uiFont
                        font.pixelSize: 13 * root.s
                        layer.enabled: true
                        layer.effect: DropShadow { color: root.sakuraPink; radius: 8; samples: 16 }
                        SequentialAnimation on opacity {
                            loops: Animation.Infinite
                            running: caret.visible
                            NumberAnimation { to: 0.2; duration: 600; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutSine }
                        }
                    }
                }
            }

            // Inset circular submit arrow.
            Item {
                id: submitBtn
                objectName: "submitArrow"
                anchors.right: parent.right
                anchors.rightMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                width: 34 * root.s
                height: 34 * root.s
                enabled: !root.context.auth.inProgress
                scale: submitMouse.containsMouse && enabled ? 1.08 : 1.0
                Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }

                Rectangle {
                    anchors.fill: parent
                    radius: 17 * root.s
                    color: submitMouse.containsMouse && submitBtn.enabled
                           ? Qt.rgba(root.sakuraPink.r, root.sakuraPink.g, root.sakuraPink.b, 0.35)
                           : Qt.rgba(root.sakuraPink.r, root.sakuraPink.g, root.sakuraPink.b, 0.15)
                    border.color: Qt.rgba(root.sakuraPink.r, root.sakuraPink.g, root.sakuraPink.b, 0.45)
                    border.width: 1 * root.s
                    Behavior on color { ColorAnimation { duration: 200 } }
                }
                Text {
                    anchors.centerIn: parent
                    text: "›"
                    color: root.sakuraLight
                    font.family: root.uiFont
                    font.pixelSize: 20 * root.s
                    opacity: root.context.auth.input.text.length > 0 && submitBtn.enabled ? 1.0 : 0.4
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                }
                MouseArea {
                    id: submitMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: submitBtn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: field.submit()
                }
                Accessible.role: Accessible.Button
                Accessible.name: "Submit password"
            }
        }

        Item { width: 1; height: 10 * root.s }

        // Real PAM status/errors where the reference error row sits, with
        // enough height for wrapping.
        Text {
            id: statusText
            objectName: "statusText"
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            height: Math.max(implicitHeight, 15 * root.s)
            verticalAlignment: Text.AlignBottom
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: text.length > 0
            text: root.context.auth.status
            color: root.context.auth.isError ? "#e08090" : root.mistWhite
            opacity: root.context.auth.isError ? 1.0 : 0.7
            font.family: root.uiFont
            font.pixelSize: 11 * root.s
            font.letterSpacing: 2 * root.s
        }
    }

    // Hover notice for unavailable affordances; never interactive.
    property string hoverNotice: ""
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: footerBar.top
        anchors.bottomMargin: 8 * root.s
        visible: root.hoverNotice.length > 0
        text: root.hoverNotice
        font.family: root.uiFont
        font.pixelSize: 11 * root.s
        color: root.sakuraLight
    }

    // Footer separator + affordance bar.
    Rectangle {
        id: footerSeparator
        objectName: "footerSeparator"
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 40 * root.s
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width - 80 * root.s
        height: 1 * root.s
        color: Qt.rgba(root.sakuraPink.r, root.sakuraPink.g, root.sakuraPink.b, 0.094)
    }

    Item {
        id: footerBar
        objectName: "footerBar"
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 40 * root.s
        anchors.rightMargin: 40 * root.s
        height: 42 * root.s

        // Left: session affordance (unavailable).
        Item {
            objectName: "sessionAffordance"
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: sessionSwitchRow.implicitWidth
            height: sessionSwitchRow.implicitHeight
            opacity: 0.6

            Row {
                id: sessionSwitchRow
                spacing: 8 * root.s
                Text {
                    text: "✦"
                    color: root.sakuraPink
                    font.pixelSize: 8 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: "Session"
                    color: "white"
                    font.family: root.uiFont
                    font.pixelSize: 11 * root.s
                    font.letterSpacing: 1 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.hoverNotice = "Session selection is not implemented yet"
                onExited: root.hoverNotice = ""
            }
            Accessible.role: Accessible.Button
            Accessible.name: "Session selection (unavailable: system actions are not yet implemented)"
        }

        // Right: power actions (unavailable), Restart then Shut Down.
        Row {
            id: powerRow
            objectName: "powerRow"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 30 * root.s
            Repeater {
                model: [
                    { name: "restartAction", label: "Restart", notice: "Restart is not implemented yet" },
                    { name: "shutdownAction", label: "Shut Down", notice: "Shut down is not implemented yet" }
                ]
                delegate: Text {
                    required property var modelData
                    objectName: modelData.name
                    text: modelData.label
                    color: "white"
                    // Unavailable: statically dimmed, never brightening into
                    // an active look on hover; hover shows the notice only.
                    opacity: 0.4
                    font.family: root.uiFont
                    font.pixelSize: 11 * root.s
                    font.letterSpacing: 1 * root.s
                    MouseArea {
                        id: powerHover
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: root.hoverNotice = modelData.notice
                        onExited: root.hoverNotice = ""
                    }
                    Accessible.role: Accessible.Button
                    Accessible.name: modelData.label + " (unavailable: system actions are not yet implemented)"
                }
            }
        }
    }

    // Nonblocking failure feedback: shake, always returning to rest.
    Connections {
        target: root.context.auth
        function onIsErrorChanged() {
            if (root.context.auth.isError)
                shakeAnim.start()
        }
    }
    SequentialAnimation {
        id: shakeAnim
        NumberAnimation { target: shakeShift; property: "x"; from: 0; to: 10 * root.s; duration: 50 }
        NumberAnimation { target: shakeShift; property: "x"; to: -9 * root.s; duration: 50 }
        NumberAnimation { target: shakeShift; property: "x"; to: 7 * root.s; duration: 50 }
        NumberAnimation { target: shakeShift; property: "x"; to: -5 * root.s; duration: 50 }
        NumberAnimation { target: shakeShift; property: "x"; to: 0; duration: 50 }
    }
}
