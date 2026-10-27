import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import "../Services"
import "../Modules/Lock" as LockModule
import "../Modules/Lock/AccentTone.js" as AccentTone

// MaterialYou (d44) — faithful adaptation of the qylock material-you
// reference (Darkkal44/qylock @ f6561e2, MIT per its metadata; see
// Themes/ATTRIBUTION.md) over Aerial's video: the light variant's
// composition — stacked bold clock + date pill left, QUICK SETTINGS grid
// and the notification-style auth card right — in a lavender/plum tonal
// palette (the user explicitly allowed hue flexibility; layout and shapes
// are the reference's).
//
// Intentional deviations (d44 plan): the video stays visible under a light
// veil so the light composition keeps its contrast; the quick-settings
// tiles and the user pill are visible but unavailable (system actions are
// a follow-up TODO — ~/Documents/Aerial/TODO.md:132-146); the card grows
// when a real PAM message needs wrapping room; native AuthField masking
// ("•" per the reference) instead of a custom editor; no entrance
// animation (input is never delayed). Compact stacking (d44 §9.1): the two
// groups stack vertically on narrow/portrait surfaces.
FocusScope {
    id: root

    required property LockContext context
    property Item backdrop: null

    focus: true

    readonly property real s: Math.max(1, height) / 768

    FontLoader {
        id: gsans
        source: "fonts/google-sans/GoogleSans-VariableFont_GRAD,opsz,wght.ttf"
    }
    readonly property string uiFont: gsans.name !== "" ? gsans.name : "Roboto, Inter, sans-serif"

    // Lavender/plum tonal hierarchy mirroring the reference's contrast.
    // d45: when the video background yields a sensed accent color, the
    // whole tonal hierarchy rotates to its hue — lightness relations are
    // preserved (light surfaces stay light, dark inks stay dark), the way
    // Material You's wallpaper monet works (user-approved full re-tint).
    // Unsensed (no video / gray frame / grab failure) → the static
    // lavender palette below, unchanged. errorText is never re-tinted:
    // errors must read as errors.
    readonly property color seed: root.context.video.accent
    readonly property bool seeded: seed.a > 0

    function tone(baseHex) {
        return AccentTone.tone(baseHex, seed.hslHue, seed.hslSaturation)
    }

    readonly property color inkDark: seeded ? tone("#35243F") : "#35243F"
    readonly property color inkMid: seeded ? tone("#4E3A5E") : "#4E3A5E"
    readonly property color accentSurface: seeded ? tone("#E9DFF5") : "#E9DFF5"
    readonly property color cardSurface: seeded ? tone("#F4EEF9") : "#F4EEF9"
    readonly property color fieldSurface: seeded ? tone("#E7DCF2") : "#E7DCF2"
    readonly property color muted: seeded ? tone("#9383A6") : "#9383A6"
    readonly property color fieldText: "#2C1F38"
    readonly property color pressedFill: seeded ? tone("#2A1D33") : "#2A1D33"
    readonly property color errorText: "#B83A5E"
    readonly property color userPillSurface: seeded ? tone("#F9F5FC") : "#F9F5FC"

    // The real PAM prompt/error text for the field slot: shown whenever it
    // differs from the routine password prompt (or is an error); at rest the
    // reference's static placeholder shows instead.
    readonly property bool hasNonRoutineStatus: context.auth.isError
        || (context.auth.status.length > 0 && context.auth.status !== context.labels.prompt)
    readonly property string slotMessage: {
        var st = context.auth.status
        if (hasNonRoutineStatus)
            return st
        return "PASSWORD REQUIRED"
    }
    readonly property bool statusNeedsWrap: slotMetrics.advanceWidth > 296 * s

    function focusInput() { field.focusField() }

    // Light veil: the light composition keeps its contrast hierarchy over
    // Aerial's (arbitrarily dark) video, which still plays beneath.
    Rectangle {
        anchors.fill: parent
        color: "#F2ECF7"
        opacity: 0.5
    }

    // One hover notice for every unavailable control; never interactive.
    property string hoverNotice: ""

    // A single presentation transform fits the actual, message-sized group.
    // Reserve a notice lane on either side of its centered height so its
    // existing center and proportions stay intact, including while hovering.
    Item {
        id: composition
        anchors.centerIn: parent
        width: group.implicitWidth
        height: group.implicitHeight
        scale: Math.max(0, Math.min(1,
            (root.width - 40 * root.s) / Math.max(1, width),
            (root.height - 40 * root.s)
                / Math.max(1, height + 2 * (12 * root.s + noticeLabel.height))))
    }

    Text {
        id: noticeLabel
        objectName: "noticeLabel"
        parent: composition
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: group.bottom
        anchors.topMargin: 12 * root.s
        width: parent.width
        height: Math.max(implicitHeight, 14 * root.s)
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        visible: root.hoverNotice.length > 0
        text: root.hoverNotice
        font.family: root.uiFont
        font.pixelSize: 11 * root.s
        font.bold: true
        color: inkMid
    }

    readonly property bool stacked: width < clockCol.implicitWidth + rightCol.implicitWidth
                                    + 96 * s + 40 * s

    GridLayout {
        id: group
        objectName: "group"
        parent: composition
        anchors.centerIn: parent
        columns: root.stacked ? 1 : 2
        columnSpacing: 96 * root.s
        rowSpacing: 24 * root.s

        // ---- Left: stacked clock + date pill ----
        Column {
            id: clockCol
            objectName: "clockCol"
            spacing: 24 * root.s
            Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter
            // d45 structural lane: the column's width is a design constant,
            // never rendered text — Google Sans digits are proportional
            // (measured: "00" ≈ 180s at 140s), so a content-sized column
            // let the wall clock move the centered group's geometry.
            width: 190 * root.s
            Layout.preferredWidth: 190 * root.s

            Column {
                spacing: -24 * root.s
                anchors.horizontalCenter: parent.horizontalCenter
                Text {
                    text: Qt.formatTime(root.context.clock.now, "hh")
                    font.family: root.uiFont
                    font.pixelSize: 140 * root.s
                    font.weight: Font.Bold
                    color: root.inkDark
                }
                Text {
                    text: Qt.formatTime(root.context.clock.now, "mm")
                    font.family: root.uiFont
                    font.pixelSize: 140 * root.s
                    font.weight: Font.Bold
                    color: root.inkMid
                }
            }

            // The pill still sizes to its text, but only WITHIN the lane —
            // clamped and elided so no locale's date string can push the
            // structure.
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(dateText.implicitWidth + 32 * root.s, parent.width)
                height: 44 * root.s
                radius: 22 * root.s
                color: root.accentSurface
                Text {
                    id: dateText
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, parent.width - 24 * root.s)
                    elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter
                    text: Qt.formatDate(root.context.clock.now, "dddd, MMM d").toUpperCase()
                    font.family: root.uiFont
                    font.pixelSize: 11 * root.s
                    font.bold: true
                    font.letterSpacing: 1 * root.s
                    color: root.inkDark
                }
            }
        }

        // ---- Right: quick settings + notification-style auth card ----
        Column {
            id: rightCol
            objectName: "rightCol"
            spacing: 24 * root.s
            Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter

            Text {
                text: "QUICK SETTINGS"
                font.family: root.uiFont
                font.pixelSize: 11 * root.s
                font.bold: true
                font.letterSpacing: 1.5 * root.s
                color: root.muted
            }

            Grid {
                id: settingsGrid
                objectName: "settingsGrid"
                columns: 2
                spacing: 16 * root.s

                MyTile {
                    label: "POWER"; sublabel: "SHUT DOWN"
                    iconSource: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><path d='M18.36 6.64a9 9 0 1 1-12.73 0'/><line x1='12' y1='2' x2='12' y2='12'/></svg>"
                    notice: "Shut down is not implemented yet"
                }
                MyTile {
                    label: "SESSION"; sublabel: "CURRENT"
                    iconSource: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><circle cx='12' cy='12' r='3'/><path d='M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82.33.06.06 0 0 1 2.83 0l-.06.06a1.65 1.65 0 0 0 .33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z'/></svg>"
                    notice: "Session selection is not implemented yet"
                }
                MyTile {
                    label: "REBOOT"; sublabel: "RESTART"
                    iconSource: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><polyline points='23 4 23 10 17 10'/><path d='M20.49 15a9 9 0 1 1-2.12-9.36L23 10'/></svg>"
                    notice: "Restart is not implemented yet"
                }
                MyTile {
                    label: "SLEEP"; sublabel: "SUSPEND"
                    iconSource: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><path d='M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z'/></svg>"
                    notice: "Suspend is not implemented yet"
                }
            }

            // Notification-style auth card; grows when a real PAM message
            // needs wrapping room rather than clipping instructions.
            Rectangle {
                id: card
                objectName: "card"
                width: 376 * root.s
                height: Math.max(180 * root.s, cardCol.implicitHeight + 40 * root.s)
                radius: 32 * root.s
                color: root.cardSurface
                transform: Translate { id: cardShake }

                Column {
                    id: cardCol
                    objectName: "cardCol"
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 20 * root.s }
                    spacing: 12 * root.s

                    Row {
                        width: parent.width
                        spacing: 8 * root.s
                        Item {
                            width: 12 * root.s
                            height: 12 * root.s
                            anchors.verticalCenter: parent.verticalCenter
                            Image {
                                id: lockIcon
                                source: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'><rect x='3' y='11' width='18' height='11' rx='2' ry='2'/><path d='M7 11V7a5 5 0 0 1 10 0v4'/></svg>"
                                anchors.fill: parent
                                sourceSize.width: 24 * root.s
                                sourceSize.height: 24 * root.s
                                visible: false
                            }
                            ColorOverlay {
                                anchors.fill: lockIcon
                                source: lockIcon
                                color: root.muted
                            }
                        }
                        Text {
                            text: "SYSTEM UI"
                            font.family: root.uiFont
                            font.pixelSize: 10 * root.s
                            font.bold: true
                            font.letterSpacing: 1 * root.s
                            color: root.muted
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: "•  now"
                            font.family: root.uiFont
                            font.pixelSize: 10 * root.s
                            color: root.muted
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    // Field: 336x52s pill.
                    Rectangle {
                        id: fieldFrame
                        objectName: "fieldFrame"
                        width: parent.width
                        height: 52 * root.s
                        radius: 26 * root.s
                        color: root.fieldSurface
                        border.width: field.hasActiveFocus ? 2 * root.s : 0
                        border.color: root.context.auth.isError ? root.errorText
                            : (field.hasActiveFocus ? root.inkDark : "transparent")
                        Behavior on border.color { ColorAnimation { duration: 150 } }

                        Text {
                            anchors.centerIn: parent
                            width: parent.width - 40 * root.s
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignHCenter
                            visible: root.context.auth.input.text.length === 0
                                     && !root.statusNeedsWrap
                            text: root.slotMessage
                            font.family: root.uiFont
                            font.pixelSize: 11 * root.s
                            font.bold: true
                            font.letterSpacing: 1.5 * root.s
                            color: root.context.auth.isError ? root.errorText : root.muted
                        }

                        LockModule.AuthField {
                            id: field
                            objectName: "field"
                            anchors { fill: parent; leftMargin: 20 * root.s; rightMargin: 20 * root.s }
                            context: root.context
                            textColor: root.fieldText
                            fontFamily: root.uiFont
                            fontPixelSize: 18 * root.s
                            fontLetterSpacing: 6 * root.s
                            horizontalAlignment: TextInput.AlignHCenter
                            maskCharacter: "•"
                        }
                    }

                    // Instructions leave the overlapping placeholder slot
                    // while typing, and wrap here whenever they need room.
                    Text {
                        objectName: "statusText"
                        visible: root.statusNeedsWrap
                                 || (root.hasNonRoutineStatus && root.context.auth.input.text.length > 0)
                        width: parent.width
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignHCenter
                        text: root.slotMessage
                        font.family: root.uiFont
                        font.pixelSize: 11 * root.s
                        font.bold: true
                        font.letterSpacing: 1.5 * root.s
                        color: root.context.auth.isError ? root.errorText : root.muted
                    }

                    // Bottom row: user pill (unavailable) + real UNLOCK pill.
                    Row {
                        width: parent.width
                        spacing: 12 * root.s

                        Rectangle {
                            id: userPill
                            objectName: "userPill"
                            width: userText.implicitWidth + 32 * root.s
                            height: 38 * root.s
                            radius: 19 * root.s
                            color: root.userPillSurface
                            opacity: 0.65
                            Text {
                                id: userText
                                objectName: "userPillText"
                                anchors.centerIn: parent
                                text: root.context.session.loginName.toUpperCase()
                                font.family: root.uiFont
                                font.pixelSize: 10 * root.s
                                font.bold: true
                                font.letterSpacing: 1 * root.s
                                color: root.fieldText
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

                        Item {
                            id: unlockPill
                            objectName: "unlockPill"
                            width: parent.width - (userText.implicitWidth + 32 * root.s) - 12 * root.s
                            height: 38 * root.s

                            Rectangle {
                                anchors.fill: parent
                                radius: 19 * root.s
                                color: unlockMouse.pressed ? root.pressedFill
                                    : (unlockMouse.containsMouse && !root.context.auth.inProgress ? root.inkMid : root.inkDark)
                                opacity: root.context.auth.inProgress ? 0.55 : 1.0
                                scale: root.context.auth.inProgress ? 1.0
                                    : (unlockMouse.pressed ? 0.95 : (unlockMouse.containsMouse ? 1.02 : 1.0))
                                Behavior on color { ColorAnimation { duration: 150 } }
                                Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutBack } }

                                Row {
                                    anchors.centerIn: parent
                                    spacing: 6 * root.s
                                    Text {
                                        text: "UNLOCK"
                                        font.family: root.uiFont
                                        font.pixelSize: 10 * root.s
                                        font.bold: true
                                        font.letterSpacing: 1.5 * root.s
                                        color: root.accentSurface
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Text {
                                        text: "➔"
                                        font.family: root.uiFont
                                        font.pixelSize: 11 * root.s
                                        color: root.accentSurface
                                        anchors.verticalCenter: parent.verticalCenter
                                        transform: Translate {
                                            x: unlockMouse.containsMouse && !root.context.auth.inProgress ? 3 * root.s : 0
                                            Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }
                                        }
                                    }
                                }

                                // MouseArea never takes keyboard focus: a
                                // click cannot steal the editor's focus
                                // mid-composition.
                                MouseArea {
                                    id: unlockMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: root.context.auth.inProgress ? Qt.ArrowCursor : Qt.PointingHandCursor
                                    onClicked: field.submit()
                                }
                                Accessible.role: Accessible.Button
                                Accessible.name: "Unlock"
                            }
                        }
                    }
                }
            }
        }
    }

    // Measure for the wrap decision without rendering twice.
    TextMetrics {
        id: slotMetrics
        font.family: root.uiFont
        font.pixelSize: 11 * root.s
        font.bold: true
        font.letterSpacing: 1.5 * root.s
        text: root.slotMessage
    }

    // Nonblocking failure feedback: card shake, returns to rest.
    Connections {
        target: root.context.auth
        function onIsErrorChanged() {
            if (root.context.auth.isError)
                cardShakeAnim.start()
        }
    }
    SequentialAnimation {
        id: cardShakeAnim
        NumberAnimation { target: cardShake; property: "x"; to: 15 * root.s; duration: 50 }
        NumberAnimation { target: cardShake; property: "x"; to: -15 * root.s; duration: 50 }
        NumberAnimation { target: cardShake; property: "x"; to: 15 * root.s; duration: 50 }
        NumberAnimation { target: cardShake; property: "x"; to: -15 * root.s; duration: 50 }
        NumberAnimation { target: cardShake; property: "x"; to: 0; duration: 50 }
    }

    // Reference tile style, used only for the unavailable quick-settings
    // grid (private inline style component, not a dispatcher).
    component MyTile: Rectangle {
        property string label: ""
        property string sublabel: ""
        property string iconSource: ""
        property string notice: ""
        width: 180 * root.s
        height: 76 * root.s
        radius: 38 * root.s
        color: accentSurface
        opacity: 0.6

        Row {
            anchors { fill: parent; leftMargin: 16 * root.s; rightMargin: 16 * root.s }
            spacing: 12 * root.s

            Rectangle {
                width: 48 * root.s
                height: 48 * root.s
                radius: 24 * root.s
                color: root.accentSurface
                anchors.verticalCenter: parent.verticalCenter
                Image {
                    id: tileIcon
                    source: iconSource
                    anchors.centerIn: parent
                    width: 20 * root.s
                    height: 20 * root.s
                    sourceSize.width: 40 * root.s
                    sourceSize.height: 40 * root.s
                    visible: false
                }
                ColorOverlay {
                    anchors.fill: tileIcon
                    source: tileIcon
                    color: root.inkDark
                }
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2 * root.s
                Text {
                    text: label
                    font.family: root.uiFont
                    font.pixelSize: 12 * root.s
                    font.bold: true
                    color: root.inkDark
                }
                Text {
                    text: sublabel
                    font.family: root.uiFont
                    font.pixelSize: 9 * root.s
                    color: root.inkMid
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.ArrowCursor
            onEntered: root.hoverNotice = notice
            onExited: root.hoverNotice = ""
        }
        Accessible.role: Accessible.Button
        Accessible.name: label + " (" + sublabel + ") (unavailable: system actions are not yet implemented)"
    }
}
