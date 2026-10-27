const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')

const read = name => fs.readFileSync(path.join(__dirname, '..', name), 'utf8')
const attribution = read('Themes/ATTRIBUTION.md')
const mit = `Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.`

// Every bundled composition's redistribution terms must travel with it.
for (const theme of ['Macintosh', 'Windows7', 'MaterialYou', 'Enfield', 'Clockwork']) {
    test(`${theme}: retained license notices`, () => {
        assert.ok(read(`Themes/${theme}.qml`).length > 0)
        if (theme === 'MaterialYou') {
            assert.match(attribution, /MaterialYou\.qml/)
            assert.match(attribution, /Copyright \(c\) 2026 Darkkal44/)
            assert.ok(attribution.includes(mit), 'complete MIT permission and warranty notice')
        } else {
            assert.match(read('LICENSE'), /GNU GENERAL PUBLIC LICENSE\s+Version 3/)
            if (theme !== 'Macintosh')
                assert.match(attribution, /GNU General Public License v3\.0/)
        }
    })
}
