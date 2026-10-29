import QtQuick
import Qt5Compat.GraphicalEffects

// Avatar (d40) — the local user avatar: the image at `source`
// ($HOME/.face, bound via LockContext.session.avatarPath) when it loads,
// else a drawn initials fallback, else a drawn person glyph when even the
// login name is unknown. No AccountsService, no NSS/getent lookup, no
// network. Missing imagery never delays locking or input: the image loads
// asynchronously and the fallback paints immediately.
Item {
    id: root

    property string source: ""        // absolute file path; "" = no image
    property string loginName: ""     // initials source for the fallback
    property int diameter: 96
    property color fallbackFill: "#3a3a3c"
    property color foreground: "#f2f2f7"
    // d44: corner radius in px; negative (the default) keeps the circle.
    // Normalized ONCE here and applied identically to the plate, the image
    // mask and the drawn person fallback's clip path.
    property real cornerRadius: -1
    readonly property real effectiveRadius: cornerRadius < 0 ? width / 2 : cornerRadius

    implicitWidth: diameter
    implicitHeight: diameter

    readonly property string initials: {
        var n = root.loginName.trim()
        if (n.length === 0)
            return ""
        var first = n.substring(0, 1)
        var spc = n.lastIndexOf(" ")
        var last = (spc >= 0 && spc + 1 < n.length) ? n.substring(spc + 1, spc + 2) : ""
        return first.toUpperCase() + last.toUpperCase()
    }

    // Fallback plate: always painted under the image; visible alone
    // whenever the image is missing, unreadable, or still decoding.
    Rectangle {
        id: plate
        anchors.fill: parent
        radius: root.effectiveRadius
        color: root.fallbackFill
        visible: img.status !== Image.Ready

        Text {
            anchors.centerIn: parent
            text: root.initials
            textFormat: Text.PlainText
            visible: root.initials.length > 0
            color: root.foreground
            font.pixelSize: Math.round(root.diameter * 0.42)
            font.weight: Font.Medium
        }

        // Drawn person glyph when there is no name to initial. The plate's
        // normalized rounded shape is the clip path, so the silhouette
        // cannot spill out.
        Canvas {
            anchors.fill: parent
            visible: root.initials.length === 0
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var w = width, h = height
                var r = root.effectiveRadius
                ctx.beginPath()
                ctx.roundedRect(0, 0, w, h, r, r)
                ctx.clip()
                ctx.fillStyle = root.foreground
                // head
                ctx.beginPath()
                ctx.arc(w / 2, h * 0.36, w * 0.17, 0, Math.PI * 2)
                ctx.fill()
                // shoulders: a dome rising from below the plate
                ctx.beginPath()
                ctx.arc(w / 2, h * 1.08, w * 0.40, Math.PI, 0)
                ctx.closePath()
                ctx.fill()
            }
        }
    }

    Image {
        id: img
        anchors.fill: parent
        source: root.source.length > 0 ? "file://" + root.source : ""
        asynchronous: true
        cache: false
        // Decode user imagery only at its displayed physical-pixel size.
        // This also follows resizing and moves between differently scaled outputs.
        sourceSize: Qt.size(Math.max(1, Math.ceil(width * Screen.devicePixelRatio)),
                            Math.max(1, Math.ceil(height * Screen.devicePixelRatio)))
        fillMode: Image.PreserveAspectCrop
        visible: status === Image.Ready

        layer.enabled: true
        layer.effect: OpacityMask {
            maskSource: maskCircle
        }
    }

    Rectangle {
        id: maskCircle
        width: root.width
        height: root.height
        radius: root.effectiveRadius
        visible: false
        layer.enabled: true
    }
}
