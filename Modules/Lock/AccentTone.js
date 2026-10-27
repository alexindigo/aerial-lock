// AccentTone.js (d45) — pure color math for video-accent sensing.
// No QML imports: unit-testable via qmltestrunner. Consumers: AccentSampler
// (seedFromPixels) and accent-aware themes (tone).
.pragma library

// RGBA byte array (Canvas ImageData.data, or any indexable bytes) plus
// dimensions → seed {h, s, l} in [0,1], or null when the frame carries no
// usable accent (grayscale, too dark, too bright, or the color share is
// negligible). Hue-bucketed histogram weighted by saturation and mid-tone
// value: saturated mid-tones win; grays/blacks/whites carry no accent.
function seedFromPixels(data, width, height) {
    var BINS = 12
    var weights = [], rs = [], gs = [], bs = []
    for (var i = 0; i < BINS; i++) { weights.push(0); rs.push(0); gs.push(0); bs.push(0) }
    var count = width * height
    for (var p = 0; p < count; p++) {
        if (data[p * 4 + 3] < 128)
            continue
        var r = data[p * 4] / 255, g = data[p * 4 + 1] / 255, b = data[p * 4 + 2] / 255
        var max = Math.max(r, g, b), min = Math.min(r, g, b)
        var l = (max + min) / 2
        if (l < 0.12 || l > 0.92)
            continue
        var d = max - min
        var s = d === 0 ? 0 : d / (1 - Math.abs(2 * l - 1))
        if (s < 0.15)
            continue
        var h
        if (max === r) h = ((g - b) / d) % 6
        else if (max === g) h = (b - r) / d + 2
        else h = (r - g) / d + 4
        h = h / 6
        if (h < 0) h += 1
        var w = s * Math.min(1, 2 * (1 - Math.abs(l - 0.5)))
        var bin = Math.min(BINS - 1, Math.floor(h * BINS))
        weights[bin] += w; rs[bin] += r * w; gs[bin] += g * w; bs[bin] += b * w
    }
    var best = -1, bestW = 0
    for (i = 0; i < BINS; i++) {
        if (weights[i] > bestW) { bestW = weights[i]; best = i }
    }
    // A mostly-gray frame with a tiny color speck does not tint the theme.
    if (best < 0 || bestW / count < 0.02)
        return null
    return rgbToHsl(rs[best] / bestW, gs[best] / bestW, bs[best] / bestW)
}

function rgbToHsl(r, g, b) {
    var max = Math.max(r, g, b), min = Math.min(r, g, b)
    var l = (max + min) / 2
    var d = max - min
    if (d === 0)
        return { h: 0, s: 0, l: l }
    var s = d / (1 - Math.abs(2 * l - 1))
    var h
    if (max === r) h = ((g - b) / d) % 6
    else if (max === g) h = (b - r) / d + 2
    else h = (r - g) / d + 4
    h = h / 6
    if (h < 0) h += 1
    return { h: h, s: s, l: l }
}

function hslToRgb(h, s, l) {
    if (s === 0)
        return { r: l, g: l, b: l }
    function hue(p, q, t) {
        if (t < 0) t += 1
        if (t > 1) t -= 1
        if (t < 1 / 6) return p + (q - p) * 6 * t
        if (t < 1 / 2) return q
        if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6
        return p
    }
    var q = l < 0.5 ? l * (1 + s) : l + s - l * s
    var p = 2 * l - q
    return { r: hue(p, q, h + 1 / 3), g: hue(p, q, h), b: hue(p, q, h - 1 / 3) }
}

function parseHex(hex) {
    var t = String(hex).charAt(0) === "#" ? String(hex).slice(1) : String(hex)
    if (t.length === 3)
        t = t.charAt(0) + t.charAt(0) + t.charAt(1) + t.charAt(1) + t.charAt(2) + t.charAt(2)
    return {
        r: parseInt(t.slice(0, 2), 16) / 255,
        g: parseInt(t.slice(2, 4), 16) / 255,
        b: parseInt(t.slice(4, 6), 16) / 255
    }
}

function hex2(v) {
    var s = Math.round(Math.max(0, Math.min(1, v)) * 255).toString(16)
    return s.length === 1 ? "0" + s : s
}

// tone: keep the base color's lightness (the theme's contrast hierarchy),
// take the seed's hue, blend saturation toward the seed but clamp so pastel
// surfaces stay pastel and inks stay near-neutral. Opaque "#rrggbb" in and
// out — alpha variants are the caller's job (Qt.rgba(accent.r, …)).
function tone(baseHex, seedH, seedS) {
    var base = parseHex(baseHex)
    var bhsl = rgbToHsl(base.r, base.g, base.b)
    var sat = bhsl.s * 0.35 + seedS * 0.65
    sat = Math.max(0.2, Math.min(0.6, sat))
    var rgb = hslToRgb(seedH, sat, bhsl.l)
    return "#" + hex2(rgb.r) + hex2(rgb.g) + hex2(rgb.b)
}
