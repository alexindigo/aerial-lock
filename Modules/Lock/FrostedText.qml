import QtQuick
import Qt5Compat.GraphicalEffects

// FrostedText (d40) — macOS-style translucent digits: the backdrop sampled
// behind the text, blurred, and painted ONLY inside the glyph silhouettes,
// plus a translucent pale tint within the same glyphs. Outside scenery
// stays sharp — this item paints nothing beyond the glyphs.
//
// Pipeline (VM-proven on live MpvQml video, d40 gate 2):
//   ShaderEffectSource samples the padded backdrop region (live) →
//   FastBlur → OpacityMask with a hidden padded Text as the alpha mask.
// QtQuick.Effects MultiEffect was the planned primitive but renders
// nothing in the nested GL substrate whenever maskEnabled is set (or when
// blurring a user-supplied ShaderEffectSource texture), on llvmpipe AND
// VirGL — Qt6 6.11.2. The Qt5Compat stack is the approved fallback
// (qylock's stack; still Qt-native, no custom shaders).
//
// Rules kept: the scenery item is the surface-local backdrop ONLY (never
// the lock surface — feedback loop); the glyph silhouette is never
// blurred (mask after blur); one sample per text run, no per-digit
// players or blurs. Null/failed scenery → plain readable tinted text.
Item {
    id: root

    property Item scenery: null
    property string text: ""
    property int fontPixelSize: 96
    property string fontFamily: ""
    property bool fontBold: true
    property int padding: 24
    property int blurRadius: 24
    property color tintColor: Qt.rgba(1, 1, 1, 0.30)
    property color fallbackColor: Qt.rgba(1, 1, 1, 0.87)

    readonly property bool sceneryActive: root.scenery !== null

    // The item is sized to the TEXT (digits), so host-side centering is
    // the text's own centerline; the padded blur/mask extend `padding`px
    // past the text in every direction for the blur kernel. Sizing to the
    // padded box instead would shift the visible text left by `padding`
    // (found via the d40 c12 centerline checks).
    implicitWidth: digits.width
    implicitHeight: digits.height

    readonly property int paddedWidth: digits.width + 2 * root.padding
    readonly property int paddedHeight: digits.height + 2 * root.padding

    // The padded backdrop region this item covers, in scenery coords.
    // mapToItem isn't reactive, so the rect is recomputed on every
    // relevant geometry change.
    function updateSampleRect() {
        if (!root.scenery) {
            sample.sourceRect = Qt.rect(0, 0, 0, 0)
            return
        }
        var p = root.mapToItem(root.scenery, 0, 0)
        sample.sourceRect = Qt.rect(p.x - root.padding, p.y - root.padding,
                                    root.paddedWidth, root.paddedHeight)
    }
    onXChanged: updateSampleRect()
    onYChanged: updateSampleRect()
    onPaddedWidthChanged: updateSampleRect()
    onPaddedHeightChanged: updateSampleRect()
    onSceneryChanged: updateSampleRect()
    Component.onCompleted: updateSampleRect()
    Connections {
        target: root.scenery
        ignoreUnknownSignals: true
        function onXChanged() { root.updateSampleRect() }
        function onYChanged() { root.updateSampleRect() }
        function onWidthChanged() { root.updateSampleRect() }
        function onHeightChanged() { root.updateSampleRect() }
    }

    // Mask: the padded glyph run. Hidden; OpacityMask re-grabs it when
    // the text changes (cached: false), so the running clock stays crisp.
    Item {
        id: maskItem
        visible: false
        width: root.paddedWidth
        height: root.paddedHeight
        Text {
            id: digits
            x: root.padding
            y: root.padding
            text: root.text
            textFormat: Text.PlainText
            color: "white"
            font.pixelSize: root.fontPixelSize
            font.family: root.fontFamily
            font.bold: root.fontBold
        }
    }

    ShaderEffectSource {
        id: sample
        sourceItem: root.scenery
        live: true
        visible: false
    }

    FastBlur {
        id: blurred
        x: -root.padding
        y: -root.padding
        width: root.paddedWidth
        height: root.paddedHeight
        source: sample
        radius: root.blurRadius
        visible: false
    }

    OpacityMask {
        x: -root.padding
        y: -root.padding
        width: root.paddedWidth
        height: root.paddedHeight
        source: blurred
        maskSource: maskItem
        cached: false
        visible: root.sceneryActive
    }

    // Translucent pale tint within the same glyphs (over the blur).
    Text {
        x: 0
        y: 0
        text: root.text
        textFormat: Text.PlainText
        color: root.tintColor
        font.pixelSize: root.fontPixelSize
        font.family: root.fontFamily
        font.bold: root.fontBold
        visible: root.sceneryActive
    }

    // Null/failed scenery: readable tinted text, no effect pipeline.
    Text {
        x: 0
        y: 0
        text: root.text
        textFormat: Text.PlainText
        color: root.fallbackColor
        font.pixelSize: root.fontPixelSize
        font.family: root.fontFamily
        font.bold: root.fontBold
        visible: !root.sceneryActive
    }
}
