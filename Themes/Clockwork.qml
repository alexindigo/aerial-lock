import QtQuick
import Qt5Compat.GraphicalEffects
import "../Services"
import "../Modules/Lock" as LockModule

// Clockwork/Orbital (d44) — faithful adaptation of the qylock
// clockwork/orbital reference (Darkkal44/qylock @ f6561e2, GPLv3; see
// Themes/ATTRIBUTION.md) over Aerial's video: the two numbered 60-tick
// scales (minute R=320s, second R=480s) centered at x=40s and cropped by
// the screen edge, rotating so the current value sits at the reading axis;
// the empty reading pill with its divider; the 110s zero-padded hour left
// of it; the date/weekday column right of it; the top-right
// SESSION/REBOOT/SHUTDOWN strip; and the right-aligned lower-right auth
// group with the borderless star-mask input, WAITING FOR KEY placeholder
// and real ENTER KEY submit.
//
// Intentional deviations (d44 plan): scale targets come from
// context.clock.now (1 Hz) with native Behavior interpolation — never a
// 16 ms wall-clock poll; no windup/sparks/flash sequences (they delayed
// the reference's doLogin); no user menu or fabricated session data (the
// SESSION/REBOOT/SHUTDOWN and username affordances are visible but
// unavailable — TODO ~/Documents/Aerial/TODO.md:132-146); no opaque
// full-screen background paint (video/solid background shows through);
// native AuthField masking/caret instead of the reference's custom editor
// row. Compact stacking (d44 §9.1): on narrow surfaces the reading
// composition (pill-centered) sits above the centered auth column; rings
// crop further at the screen edges, which is intentional.
FocusScope {
    id: root

    required property LockContext context
    property Item backdrop: null

    focus: true

    readonly property real s: Math.max(1, height) / 768
    readonly property real marginR: 80 * s

    FontLoader {
        id: outfitFont
        source: "fonts/outfit/Outfit-Black.ttf"
    }
    readonly property string uiFont: outfitFont.name !== "" ? outfitFont.name : "sans-serif"

    // Reference dark palette, d45-raised: the qylock grays were tuned for
    // the reference's dark scene and washed out over bright video. The
    // dim-vs-main hierarchy is unchanged; the gray tier is lighter and the
    // dim texts carry a dark shadow so foam highlights don't eat them.
    readonly property color mainText: "#ffffff"
    readonly property color dimText: "#b8b8b8"
    readonly property color subColor: "#a0a0a0"
    readonly property color pillColor: "#080808"
    readonly property color pillBorder: "#1a1a1a"
    readonly property color pillInnerLine: "#222222"
    readonly property color inputWaitColor: "#888888"
    readonly property color errorColor: "#ff4444"

    function focusInput() { field.focusField() }

    // ---- Scale rotation, ticked from the shared 1 Hz clock ----
    // Revolution counters + per-tick fractions: targets decrease
    // monotonically, wrapping steps them exactly one tick with no extra
    // revolution and no backward spin. The math reads only the counters and
    // the current fraction — never the animated presentation properties
    // (d43's floor-of-animated-value logic spun a full extra revolution per
    // tick under Behavior interpolation; caught in the d44 capture review).
    property real secondTarget: 0
    property real minuteTarget: 0
    property real secondAngle: secondTarget
    property real minuteAngle: minuteTarget
    property real _secRevs: 0
    property real _minRevs: 0
    property real _prevSec: -1
    property real _prevMin: -1
    property bool _snap: false

    function updateScales() {
        var now = root.context.clock.now
        var sec = now.getSeconds() + now.getMilliseconds() / 1000
        var min = now.getMinutes() + now.getSeconds() / 60

        if (_prevSec >= 0) {
            // Forward wrap across the 59.x -> 0.x boundary only.
            if (sec < _prevSec && _prevSec >= 50 && sec < 10)
                _secRevs += 360
            else if (Math.abs(sec - _prevSec) > 2)
                _snap = true     // clock correction: jump, don't animate
            if (min < _prevMin && _prevMin >= 59 && min < 1)
                _minRevs += 360
        }
        _prevSec = sec
        _prevMin = min

        secondTarget = -(_secRevs + (sec / 60) * 360)
        minuteTarget = -(_minRevs + (min / 60) * 360)
        _snap = false
    }

    Connections {
        target: root.context.clock
        function onNowChanged() { root.updateScales() }
    }
    Component.onCompleted: {
        // The initial state IS the time; no startup sweep.
        _snap = true
        root.updateScales()
        _snap = false
    }

    Behavior on secondAngle { NumberAnimation { duration: 300; easing.type: Easing.InOutCubic; } enabled: !root._snap }
    Behavior on minuteAngle { NumberAnimation { duration: 300; easing.type: Easing.InOutCubic; } enabled: !root._snap }

    // ---- Reading composition ----
    // Narrow mode (compact stacking, d44 §9.1): the hour+pill group is
    // centered horizontally, the date column moves below the pill, and the
    // auth column centers below; the rings crop further at the screen
    // edges, which is intentional. Wide keeps the reference's left-anchored
    // composition. The trigger is where the date column would leave the
    // surface (reading group right edge 830s plus margin).
    readonly property bool narrowOrbital: root.width < 870 * root.s
    // The intact hour..pill group spans [230s - hourWidth, 600s] of the
    // container; its center and the scale's fixed origin are bound from the
    // REAL hour width, so the group is centered exactly at any narrow width.
    readonly property real hourPillCenter: (230 * s - hourText.width + 600 * s) / 2
    readonly property real narrowScale: narrowOrbital
        ? Math.min(1, (root.width - 40 * root.s) / (370 * root.s + hourText.width))
        : 1

    Item {
        id: clockContainer
        objectName: "clockContainer"
        width: 800 * root.s
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: narrowOrbital ? undefined : parent.left
        anchors.horizontalCenter: narrowOrbital ? parent.horizontalCenter : undefined
        anchors.horizontalCenterOffset: narrowOrbital ? 400 * root.s - root.hourPillCenter : 0
        transform: Scale {
            origin.x: root.hourPillCenter
            origin.y: clockContainer.height / 2
            xScale: root.narrowScale
            yScale: root.narrowScale
        }

        readonly property real cx: 40 * root.s
        readonly property real cy: height * 0.5
        readonly property real minR: 320 * root.s
        readonly property real secR: 480 * root.s

        // The reading window at the axis: a prominent frosted frame. The
        // current values read THROUGH it — the sharp near-axis content
        // renders above it (z: 10), matching the reference's layering.
        Rectangle {
            id: indicatorPill
            objectName: "readingPill"
            z: 1
            x: clockContainer.cx + 230 * root.s
            anchors.verticalCenter: parent.verticalCenter
            width: 330 * root.s
            height: 90 * root.s
            radius: 45 * root.s
            color: Qt.rgba(1, 1, 1, 0.055)
            border.color: Qt.rgba(1, 1, 1, 0.16)
            border.width: 1 * root.s
            Rectangle {
                x: 170 * root.s
                anchors.verticalCenter: parent.verticalCenter
                width: 1 * root.s
                height: 35 * root.s
                color: Qt.rgba(1, 1, 1, 0.22)
            }
        }

        // Soft layer: the whole scales, blurred and dimmed — the off-axis
        // field recedes. One offscreen render of the group per tick.
        Item {
            id: scalesSoft
            anchors.fill: parent
            layer.enabled: true
            layer.effect: FastBlur { radius: 2.2 * root.s }

            ScaleRing {
                anchors.fill: parent
                angle: root.minuteAngle
                radius: clockContainer.minR
                labelRadius: clockContainer.minR - 35 * root.s
                majorW: 2 * root.s; majorH: 18 * root.s
                minorW: 1 * root.s; minorH: 10 * root.s
                labelSize: 22 * root.s
                sharpOnly: false
            }
            ScaleRing {
                anchors.fill: parent
                angle: root.secondAngle
                radius: clockContainer.secR
                labelRadius: clockContainer.secR - 30 * root.s
                majorW: 1.5 * root.s; majorH: 13 * root.s
                minorW: 1 * root.s; minorH: 8 * root.s
                labelSize: 16 * root.s
                sharpOnly: false
            }
        }

        // Sharp layer: only near-axis content, full bright, above the pill.
        Item {
            id: scalesSharp
            anchors.fill: parent
            z: 10

            ScaleRing {
                anchors.fill: parent
                angle: root.minuteAngle
                radius: clockContainer.minR
                labelRadius: clockContainer.minR - 35 * root.s
                majorW: 2 * root.s; majorH: 18 * root.s
                minorW: 1 * root.s; minorH: 10 * root.s
                labelSize: 22 * root.s
                sharpOnly: true
            }
            ScaleRing {
                anchors.fill: parent
                angle: root.secondAngle
                radius: clockContainer.secR
                labelRadius: clockContainer.secR - 30 * root.s
                majorW: 1.5 * root.s; majorH: 13 * root.s
                minorW: 1 * root.s; minorH: 8 * root.s
                labelSize: 16 * root.s
                sharpOnly: true
            }
        }

        // Hour, left of the pill.
        Text {
            id: hourText
            objectName: "hourText"
            anchors.right: indicatorPill.left
            anchors.rightMargin: 40 * root.s
            anchors.verticalCenter: parent.verticalCenter
            text: Qt.formatTime(root.context.clock.now, "HH")
            textFormat: Text.PlainText
            font.family: root.uiFont
            font.pixelSize: 110 * root.s
            font.weight: Font.Black
            color: root.mainText
        }

        // Date / weekday, right of the pill (below it in narrow mode).
        Column {
            id: dateCol
            objectName: "dateColumn"
            anchors.left: indicatorPill.right
            anchors.leftMargin: 110 * root.s
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5 * root.s
            Item { width: 1; height: root.narrowOrbital ? 24 * root.s : 0 }
            Text {
                text: Qt.formatDate(root.context.clock.now, "dd MMM yyyy").toUpperCase()
                textFormat: Text.PlainText
                font.family: root.uiFont
                font.pixelSize: 13 * root.s
                font.letterSpacing: 4 * root.s
                color: root.subColor
                style: Text.Raised
                styleColor: "#80000000"
            }
            Text {
                text: Qt.formatDate(root.context.clock.now, "dddd").toUpperCase()
                textFormat: Text.PlainText
                font.family: root.uiFont
                font.pixelSize: 18 * root.s
                font.letterSpacing: 8 * root.s
                font.weight: Font.Bold
                color: root.mainText
            }
        }

        states: State {
            name: "narrow"
            when: root.narrowOrbital
            AnchorChanges {
                target: dateCol
                anchors.left: undefined
                anchors.verticalCenter: undefined
                anchors.horizontalCenter: indicatorPill.horizontalCenter
                anchors.top: indicatorPill.bottom
            }
        }
    }

    // ---- Top-right actions strip (unavailable) ----
    Row {
        id: actionsRow
        objectName: "actionsRow"
        anchors.right: parent.right
        anchors.rightMargin: root.marginR
        anchors.top: parent.top
        anchors.topMargin: 50 * root.s
        spacing: 25 * root.s

        CwAction { objectName: "sessionAction"; label: "Session"; notice: "Session selection is not implemented yet" }
        Rectangle { width: 1 * root.s; height: 10 * root.s; color: root.pillBorder; anchors.verticalCenter: parent.verticalCenter }
        CwAction { objectName: "rebootAction"; label: "Reboot"; notice: "Reboot is not implemented yet" }
        Rectangle { width: 1 * root.s; height: 10 * root.s; color: root.pillBorder; anchors.verticalCenter: parent.verticalCenter }
        CwAction { objectName: "shutdownAction"; label: "Shutdown"; notice: "Shut down is not implemented yet" }
    }

    // Hover notice for unavailable controls; never interactive.
    property string hoverNotice: ""
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 16 * root.s
        visible: root.hoverNotice.length > 0
        text: root.hoverNotice
        textFormat: Text.PlainText
        font.family: root.uiFont
        font.pixelSize: 11 * root.s
        font.letterSpacing: 2 * root.s
        color: root.dimText
        style: Text.Raised
        styleColor: "#80000000"
    }

    // ---- Lower-right auth group ----
    Column {
        id: loginPanel
        objectName: "authColumn"
        anchors.right: narrowOrbital ? undefined : parent.right
        anchors.rightMargin: narrowOrbital ? 0 : root.marginR
        anchors.horizontalCenter: narrowOrbital ? parent.horizontalCenter : undefined
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 80 * root.s
        width: Math.min(350 * root.s, root.width - 40 * root.s)
        spacing: 8 * root.s

        transform: Translate { id: shakeShift }

        // Username (selector unavailable).
        Item {
            objectName: "userSelector"
            width: parent.width
            height: 32 * root.s
            opacity: 0.7
            Text {
                id: userNameDisp
                objectName: "userName"
                anchors.right: parent.right
                text: root.context.session.loginName.toUpperCase()
                textFormat: Text.PlainText
                font.family: root.uiFont
                font.pixelSize: 18 * root.s
                font.weight: Font.Bold
                font.letterSpacing: 8 * root.s
                color: root.dimText
                style: Text.Raised
                styleColor: "#80000000"
            }
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.hoverNotice = "Switching users is not implemented yet"
                onExited: root.hoverNotice = ""
            }
            Accessible.role: Accessible.Button
            Accessible.name: "User " + root.context.session.loginName + " (switching unavailable: system actions are not yet implemented)"
        }

        // Borderless star-mask input, right-aligned, needle caret.
        Item {
            id: inputRow
            objectName: "inputRow"
            width: parent.width
            height: 30 * root.s

            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.context.auth.input.text.length === 0
                         && root.context.auth.status.length === 0
                text: "WAITING FOR KEY"
                font.family: root.uiFont
                font.pixelSize: 10 * root.s
                font.letterSpacing: 4 * root.s
                color: root.inputWaitColor
                style: Text.Raised
                styleColor: "#80000000"
                opacity: 0.4
                Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.InOutSine } }
            }

            LockModule.AuthField {
                id: field
                objectName: "field"
                anchors.fill: parent
                context: root.context
                textColor: root.dimText
                fontFamily: root.uiFont
                fontPixelSize: 14 * root.s
                fontLetterSpacing: 10 * root.s
                horizontalAlignment: TextInput.AlignRight
                maskCharacter: "✦"
                cursorDelegate: Component {
                    Rectangle {
                        id: caret
                        width: 1.5 * root.s
                        height: 12 * root.s
                        color: root.mainText
                        SequentialAnimation on opacity {
                            loops: Animation.Infinite
                            running: caret.visible
                            NumberAnimation { to: 0.1; duration: 450 }
                            NumberAnimation { to: 1.0; duration: 450 }
                        }
                    }
                }
            }
        }

        // ENTER KEY — the real submit control.
        Item {
            id: enterKey
            objectName: "enterKey"
            width: parent.width
            height: 40 * root.s

            Text {
                id: loginBtn
                objectName: "enterKeyText"
                anchors.right: parent.right
                anchors.rightMargin: btnMa.containsMouse && root.context.auth.input.text.length > 0
                                     && !root.context.auth.inProgress ? 25 * root.s : 0
                text: "ENTER KEY"
                font.family: root.uiFont
                font.pixelSize: 11 * root.s
                font.letterSpacing: 4 * root.s
                font.weight: Font.Bold
                color: btnMa.containsMouse && !root.context.auth.inProgress ? root.mainText : root.dimText
                style: Text.Raised
                styleColor: "#80000000"
                Behavior on color { ColorAnimation { duration: 200 } }
                Behavior on anchors.rightMargin { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                opacity: root.context.auth.input.text.length > 0 && !root.context.auth.inProgress ? 1.0 : 0
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }
            Text {
                text: "✦"
                anchors.left: loginBtn.right
                anchors.leftMargin: 8 * root.s
                anchors.verticalCenter: loginBtn.verticalCenter
                color: root.mainText
                opacity: btnMa.containsMouse && root.context.auth.input.text.length > 0
                         && !root.context.auth.inProgress ? 1.0 : 0
                font.pixelSize: 10 * root.s
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }
            MouseArea {
                id: btnMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: root.context.auth.inProgress ? Qt.ArrowCursor : Qt.PointingHandCursor
                onClicked: field.submit()
            }
            Accessible.role: Accessible.Button
            Accessible.name: "Unlock"
        }

        // Status row: real PAM prompts/errors, right-aligned, wrapping.
        Text {
            id: statusText
            objectName: "statusText"
            width: parent.width
            height: Math.max(implicitHeight, 15 * root.s)
            verticalAlignment: Text.AlignBottom
            horizontalAlignment: Text.AlignRight
            wrapMode: Text.WordWrap
            visible: text.length > 0
            text: root.context.auth.status
            textFormat: Text.PlainText
            color: root.context.auth.isError ? root.errorColor : root.dimText
            style: Text.Raised
            styleColor: "#80000000"
            font.family: root.uiFont
            font.pixelSize: 10 * root.s
            font.letterSpacing: 2 * root.s
        }
    }

    // Presentation-only failure motion, independent of the active anchors.
    Connections {
        target: root.context.auth
        function onIsErrorChanged() {
            if (root.context.auth.isError)
                shake.start()
        }
    }
    SequentialAnimation {
        id: shake
        NumberAnimation { target: shakeShift; property: "x"; from: 0; to: -10 * root.s; duration: 50; easing.type: Easing.InOutSine }
        NumberAnimation { target: shakeShift; property: "x"; to: 10 * root.s; duration: 50; easing.type: Easing.InOutSine }
        NumberAnimation { target: shakeShift; property: "x"; to: 0; duration: 50; easing.type: Easing.InOutSine }
    }

    // One 60-tick numbered scale. Shared by the soft (blurred, dim) and
    // sharp (near-axis, bright) layers so the trigonometry is written once.
    component ScaleRing: Item {
        id: ring
        required property real angle
        required property real radius
        required property real labelRadius
        required property real majorW
        required property real majorH
        required property real minorW
        required property real minorH
        required property real labelSize
        property bool sharpOnly: false

        Repeater {
            model: 60
            delegate: Item {
                z: ring.sharpOnly ? 10 : 0
                property real base: index * 6
                property real relAngle: {
                    var a = (base + ring.angle) % 360
                    if (a > 180) a -= 360
                    if (a < -180) a += 360
                    return a
                }
                property real spotlight: Math.max(0, 1.0 - Math.abs(relAngle) / 4.0)
                property bool isMajor: index % 5 === 0
                property real disp: (base + ring.angle) * Math.PI / 180
                property real tx: clockContainer.cx + ring.radius * Math.cos(disp)
                property real ty: clockContainer.cy + ring.radius * Math.sin(disp)
                visible: tx > -600 * root.s && tx < root.width + 600 * root.s
                         && (!ring.sharpOnly || spotlight > 0)
                Rectangle {
                    x: parent.tx - width / 2
                    y: parent.ty - height / 2
                    width: isMajor ? ring.majorW : ring.minorW
                    height: isMajor ? ring.majorH : ring.minorH
                    color: ring.sharpOnly
                        ? Qt.rgba(1, 1, 1, 1.0)
                        // d45: off-axis alphas raised — the ticks vanished
                        // over bright video (user-directed contrast fix).
                        : Qt.rgba(1, 1, 1, spotlight > 0 ? 0.55 : (isMajor ? 0.30 : 0.16))
                    rotation: disp * 180 / Math.PI + 90
                    antialiasing: true
                    transformOrigin: Item.Center
                }
                Text {
                    visible: isMajor
                    property real nRad: ring.labelRadius
                    x: clockContainer.cx + nRad * Math.cos(disp) - width / 2
                    y: clockContainer.cy + nRad * Math.sin(disp) - height / 2
                    text: String(index).padStart(2, '0')
                    textFormat: Text.PlainText
                    font.family: root.uiFont
                    font.pixelSize: ring.labelSize
                    font.weight: spotlight > 0.5 ? Font.Bold : Font.Normal
                    color: ring.sharpOnly
                        ? Qt.rgba(1, 1, 1, 1.0)
                        : Qt.rgba(1, 1, 1, spotlight > 0 ? 0.3 : 0.16)
                    rotation: disp * 180 / Math.PI
                    transformOrigin: Item.Center
                    antialiasing: true
                }
            }
        }
    }

    // Reference action-strip style, used only for the unavailable top-right
    // controls (private inline style component, not a dispatcher).
    component CwAction: Item {
        property string label: ""
        property string notice: ""
        width: actTxt.width + 20 * root.s
        height: 15 * root.s
        opacity: 0.7
        Text {
            id: actTxt
            anchors.right: parent.right
            text: label.toUpperCase()
            textFormat: Text.PlainText
            color: root.dimText
            font.family: root.uiFont
            font.pixelSize: 10 * root.s
            font.letterSpacing: 3 * root.s
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
