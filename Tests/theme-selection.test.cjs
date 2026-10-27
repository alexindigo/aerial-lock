// Pure-unit tests for Services/ThemeSelection.js (d40 plan §6 row 10).
// Runs with plain node: node --test Tests/theme-selection.test.cjs
const test = require('node:test')
const assert = require('node:assert')
const fs = require('node:fs')
const path = require('node:path')

const src = fs.readFileSync(path.join(__dirname, '../Services/ThemeSelection.js'), 'utf8')
globalThis.eval(src)
const { normalizeWords, selectPlaylist } = globalThis

const inv = [
    { path: '/cache/alps-mountain-range.mp4', matchText: 'Alps Mountain Range' },
    { path: '/cache/city-night.mp4', matchText: 'City Night' },
    { path: '/local/Snowy-Mountain.mp4', matchText: 'Snowy-Mountain' },  // local: filename stem
    { path: '/local/sunset.mp4', matchText: 'sunset' },
]

test('normalizeWords: lowercase, split non-alnum, drop empties', () => {
    assert.deepStrictEqual(normalizeWords('Alps Mountain Range'), ['alps', 'mountain', 'range'])
    assert.deepStrictEqual(normalizeWords('Snowy-Mountain'), ['snowy', 'mountain'])
    assert.deepStrictEqual(normalizeWords(''), [])
    assert.deepStrictEqual(normalizeWords(null), [])
    assert.deepStrictEqual(normalizeWords(42), [])
})

test('matches whole words only — no substring accidents', () => {
    // "mountain" topic must not match "mountainous"; "sun" must not match "sunset"
    const out = selectPlaylist([
        { path: '/a/mountainous.mp4', matchText: 'mountainous' },
        { path: '/a/sunset.mp4', matchText: 'sunset' },
    ], ['mountain', 'sun'])
    assert.deepStrictEqual(out, ['/a/mountainous.mp4', '/a/sunset.mp4'], 'no match → full pool')
})

test('topic matches case-insensitively in labels and filenames', () => {
    const out = selectPlaylist(inv, ['MOUNTAIN'])
    assert.deepStrictEqual(out, ['/cache/alps-mountain-range.mp4', '/local/Snowy-Mountain.mp4'])
})

test('OR semantics: any declared topic matches', () => {
    const out = selectPlaylist(inv, ['city', 'mountain'])
    assert.deepStrictEqual(out, ['/cache/alps-mountain-range.mp4', '/cache/city-night.mp4', '/local/Snowy-Mountain.mp4'])
})

test('empty topics → full pool, original order', () => {
    const out = selectPlaylist(inv, [])
    assert.deepStrictEqual(out, inv.map(i => i.path))
})

test('no matches → full pool, original order', () => {
    const out = selectPlaylist(inv, ['desert'])
    assert.deepStrictEqual(out, inv.map(i => i.path))
})

test('non-string topics are ignored; wrong types → no preference', () => {
    assert.deepStrictEqual(selectPlaylist(inv, null), inv.map(i => i.path))
    assert.deepStrictEqual(selectPlaylist(inv, [42, {}]), inv.map(i => i.path))
})

test('selection is stable: matching preserves inventory order', () => {
    const inv2 = [
        { path: '/c1.mp4', matchText: 'mountain' },
        { path: '/a1.mp4', matchText: 'city' },
        { path: '/b1.mp4', matchText: 'mountain' },
    ]
    assert.deepStrictEqual(selectPlaylist(inv2, ['mountain']), ['/c1.mp4', '/b1.mp4'])
})
