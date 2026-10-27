import QtQuick
import QtTest
import "../Modules/Lock/AccentTone.js" as AccentTone

// d45: AccentTone.js contract — seed extraction from pixel arrays and the
// tonal re-tint mapping. Pure JS: no MpvQml, no lock machinery.
TestCase {
    id: root
    name: "AccentTone"

    function solidPixels(r, g, b, count) {
        var data = new Uint8ClampedArray(count * 4)
        for (var i = 0; i < count; i++) {
            data[i * 4] = r
            data[i * 4 + 1] = g
            data[i * 4 + 2] = b
            data[i * 4 + 3] = 255
        }
        return data
    }

    function test_red_frame_yields_red_seed() {
        var seed = AccentTone.seedFromPixels(solidPixels(200, 40, 30, 64 * 40), 64, 40)
        verify(seed !== null, "red frame yields a seed")
        verify(seed.h < 0.08 || seed.h > 0.92, "seed hue is red, got " + seed.h)
        verify(seed.s > 0.5, "red frame is saturated, got " + seed.s)
    }

    function test_teal_frame_yields_teal_seed() {
        var seed = AccentTone.seedFromPixels(solidPixels(30, 130, 140, 64 * 40), 64, 40)
        verify(seed !== null, "teal frame yields a seed")
        verify(seed.h > 0.45 && seed.h < 0.6, "seed hue is teal, got " + seed.h)
    }

    function test_gray_frame_yields_no_seed() {
        var seed = AccentTone.seedFromPixels(solidPixels(120, 120, 120, 64 * 40), 64, 40)
        compare(seed, null, "grayscale carries no accent")
    }

    function test_near_black_frame_yields_no_seed() {
        var seed = AccentTone.seedFromPixels(solidPixels(12, 10, 14, 64 * 40), 64, 40)
        compare(seed, null, "near-black frame yields no seed")
    }

    function test_near_white_frame_yields_no_seed() {
        var seed = AccentTone.seedFromPixels(solidPixels(248, 246, 250, 64 * 40), 64, 40)
        compare(seed, null, "near-white frame yields no seed")
    }

    function test_tiny_color_speck_yields_no_seed() {
        // 1% saturated red in a gray field: below the 2% share guard.
        var count = 64 * 40
        var data = solidPixels(120, 120, 120, count)
        for (var i = 0; i < Math.floor(count * 0.01); i++) {
            data[i * 4] = 220
            data[i * 4 + 1] = 30
            data[i * 4 + 2] = 30
        }
        var seed = AccentTone.seedFromPixels(data, 64, 40)
        compare(seed, null, "a speck must not tint the theme")
    }

    function test_transparent_pixels_are_skipped() {
        var count = 64 * 40
        var data = solidPixels(200, 40, 30, count)
        for (var i = 0; i < count; i++)
            data[i * 4 + 3] = 0
        var seed = AccentTone.seedFromPixels(data, 64, 40)
        compare(seed, null, "fully transparent frame yields no seed")
    }

    function test_tone_keeps_lightness_swaps_hue() {
        var base = "#E9DFF5"   // light lavender surface
        var result = AccentTone.tone(base, 0.52, 0.55)   // teal seed
        var tinted = AccentTone.parseHex(result)
        var thsl = AccentTone.rgbToHsl(tinted.r, tinted.g, tinted.b)
        var baseRgb = AccentTone.parseHex(base)
        var baseHsl = AccentTone.rgbToHsl(baseRgb.r, baseRgb.g, baseRgb.b)
        verify(Math.abs(thsl.h - 0.52) < 0.06, "hue follows the seed, got " + thsl.h)
        verify(Math.abs(thsl.l - baseHsl.l) < 0.06,
               "lightness keeps the hierarchy, got " + thsl.l + " vs " + baseHsl.l)
    }

    function test_tone_clamps_saturation() {
        var result = AccentTone.tone("#35243F", 0.0, 1.0)   // dark ink, max-sat seed
        var tinted = AccentTone.parseHex(result)
        var thsl = AccentTone.rgbToHsl(tinted.r, tinted.g, tinted.b)
        verify(thsl.s <= 0.62, "saturation clamped, got " + thsl.s)
        verify(thsl.l < 0.3, "ink stays dark, got " + thsl.l)
    }

    function test_tone_neutral_seed_still_tints_hue_only() {
        // A low-saturation seed still rotates hue; the blend keeps the
        // result quiet rather than neon.
        var result = AccentTone.tone("#9383A6", 0.3, 0.2)
        var thsl = AccentTone.rgbToHsl(AccentTone.parseHex(result).r,
                                       AccentTone.parseHex(result).g,
                                       AccentTone.parseHex(result).b)
        verify(thsl.s >= 0.18 && thsl.s <= 0.62, "saturation within clamp band, got " + thsl.s)
    }
}
