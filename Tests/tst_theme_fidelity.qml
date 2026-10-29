import QtQuick
import QtTest
import "../Services" as Services

// d44 theme fidelity: element inventory and mapped-rectangle geometry of
// the four qylock-derived themes against the frozen inventory
// (plans/d44-theme-fidelity/inventory.md), plus disabled-control honesty
// and real status/prompt rendering. All geometry is asserted in s-scaled
// pixels at a 1280x800 surface unless a test says otherwise. Synthetic
// strings only.
Item {
    id: root
    width: 1280
    height: 800

    Component {
        id: contextComponent
        Services.LockContext {}
    }

    TestCase {
        id: tc
        name: "ThemeFidelity"
        when: windowShown

        property var ctx: null
        property var theme: null

        readonly property var bundledThemes: ["Macintosh.qml", "Windows7.qml", "MaterialYou.qml",
                                              "Enfield.qml", "Clockwork.qml"]

        function test_hidden_caret_stops_data() {
            return [{tag: "enfield", filename: "Enfield.qml"},
                    {tag: "clockwork", filename: "Clockwork.qml"}]
        }

        function test_hidden_caret_stops(data) {
            load(data.filename)
            var cores = []
            collectCores(theme, cores)
            var caret = cores[0].cursorDelegate.createObject(theme)
            verify(caret !== null)
            wait(200)
            theme.visible = false
            wait(100)
            var stopped = caret.opacity
            wait(350)
            compare(caret.opacity, stopped, "hidden themes must stop their perpetual caret work")
            caret.destroy()
        }

        function test_failure_motion_data() {
            var rows = []
            for (var i = 0; i < bundledThemes.length; i++) {
                for (var narrow = 0; narrow < 2; narrow++)
                    rows.push({tag: bundledThemes[i] + (narrow ? "-narrow" : "-wide"),
                               filename: bundledThemes[i], w: narrow ? 492 : 1280})
            }
            return rows
        }

        function test_failure_motion(data) {
            load(data.filename, data.w, 768)
            wait(100) // allow asynchronous bundled fonts and positioners to settle
            var cores = []
            collectCores(theme, cores)
            compare(cores.length, 1)
            var panel = cores[0]
            var vertical = data.filename === "Windows7.qml"
            function position() {
                var p = panel.mapToItem(theme, 0, 0)
                return vertical ? p.y : p.x
            }
            var rest = position()
            ctx.auth.isError = true
            var excursion = 0
            for (var i = 0; i < 22; i++) {
                wait(16)
                excursion = Math.max(excursion, Math.abs(position() - rest))
            }
            if (data.filename === "Macintosh.qml")
                close(excursion, 0, "Macintosh has no failure motion")
            else
                verify(excursion > 1, data.filename + ": failure moves the mapped field in either layout")
            close(position(), rest, "failure motion returns to its resting position")
        }

        function collectStatusTexts(item, text, out) {
            if (item.text === text && item.visible && item.opacity > 0 && item.height > 0)
                out.push(item)
            for (var i = 0; i < item.children.length; i++)
                collectStatusTexts(item.children[i], text, out)
        }

        function test_prompt_while_typing_data() {
            var rows = []
            for (var i = 0; i < bundledThemes.length; i++) {
                for (var error = 0; error < 2; error++) {
                    for (var longMessage = 0; longMessage < 2; longMessage++)
                        rows.push({tag: bundledThemes[i] + "-" + error + "-" + longMessage,
                                   filename: bundledThemes[i], error: !!error,
                                   message: longMessage
                                       ? "Verification challenge: enter the six-digit code from your security token, followed by the recovery suffix supplied by your administrator."
                                       : "Token code:"})
                }
            }
            return rows
        }

        function test_prompt_while_typing(data) {
            load(data.filename)
            ctx.auth.status = data.message
            ctx.auth.isError = data.error
            theme.focusInput()
            keyClick(Qt.Key_A)
            tryCompare(ctx.auth.input, "text", "a")
            tryVerify(function () {
                var texts = []
                collectStatusTexts(theme, data.message, texts)
                return texts.length > 0
            }, 500, "non-routine instructions stay visible while entering a response")
        }

        function insideSurface(obj, what) {
            var tl = obj.mapToItem(theme, 0, 0)
            var br = obj.mapToItem(theme, obj.width, obj.height)
            verify(br.x > tl.x && br.y > tl.y, what + " has area")
            verify(tl.x >= -0.75 && tl.y >= -0.75
                   && br.x <= theme.width + 0.75 && br.y <= theme.height + 0.75,
                   what + " within " + theme.width + "x" + theme.height
                   + ": (" + tl.x + ", " + tl.y + ")..(" + br.x + ", " + br.y + ")")
        }

        function test_portrait_bounds_data() {
            var rows = []
            var sizes = [[492, 768], [600, 1024], [768, 1366]]
            for (var i = 0; i < bundledThemes.length; i++) {
                for (var j = 0; j < sizes.length; j++) {
                    for (var longMessage = 0; longMessage < 2; longMessage++)
                        rows.push({tag: bundledThemes[i] + "-" + sizes[j].join("x") + "-" + longMessage,
                                   filename: bundledThemes[i], w: sizes[j][0], h: sizes[j][1],
                                   message: longMessage ? ("Verification challenge: enter the six-digit code from your security token, followed by the recovery suffix supplied by your administrator. Keep this instruction visible until the complete response has been entered. ").repeat(3) : ""})
                }
            }
            return rows
        }

        function test_portrait_bounds(data) {
            load(data.filename, data.w, data.h)
            ctx.auth.status = data.message
            if (theme.hoverNotice !== undefined)
                theme.hoverNotice = "Switching users is not implemented yet"
            wait(100)
            waitForRendering(theme)
            var cores = []
            collectCores(theme, cores)
            compare(cores.length, 1)
            insideSurface(cores[0], "auth field")
            var submitNames = {"Windows7.qml": "submitArrow", "MaterialYou.qml": "unlockPill",
                               "Enfield.qml": "submitArrow", "Clockwork.qml": "enterKey"}
            if (submitNames[data.filename])
                insideSurface(region(submitNames[data.filename]).obj, "submit control")
            // Macintosh's submission surface is the field (Return), not a button.
            if (data.message.length > 0) {
                var texts = []
                collectStatusTexts(theme, data.message, texts)
                verify(texts.length > 0, "wrapped status visible")
                for (var i = 0; i < texts.length; i++)
                    insideSurface(texts[i], "wrapped status")
            }
            if (theme.hoverNotice !== undefined) {
                var notices = []
                collectStatusTexts(theme, theme.hoverNotice, notices)
                verify(notices.length > 0, "hover notice visible")
                for (var j = 0; j < notices.length; j++)
                    insideSurface(notices[j], "hover notice")
            }
        }

        function init() {
            ctx = createTemporaryObject(contextComponent, root)
            ctx.session.loginName = "tester"
            // Simulate the controller: the initial prompt sits in the status.
            ctx.auth.status = ctx.labels.prompt
            theme = null
        }

        function cleanup() {
            if (theme) {
                theme.destroy()
                theme = null
                // Drain deferred consumer destruction before QtTest removes ctx.
                wait(0)
            }
        }

        function load(filename, w, h) {
            var component = Qt.createComponent("../Themes/" + filename)
            compare(component.status, Component.Ready, component.errorString())
            theme = component.createObject(root, {
                "context": ctx,
                "width": w === undefined ? 1280 : w,
                "height": h === undefined ? 800 : h
            })
            verify(theme !== null)
            return theme
        }

        function findByName(item, name) {
            if (item.objectName === name)
                return item
            for (var i = 0; i < item.children.length; i++) {
                var found = findByName(item.children[i], name)
                if (found)
                    return found
            }
            return null
        }

        function region(name) {
            var obj = findByName(theme, name)
            verify(obj !== null, "region missing: " + name)
            // Map BOTH corners through the transform chain: a scaled
            // container (narrow Orbital) must show up in the measurement —
            // layout width/height alone would miss it.
            var tl = obj.mapToItem(theme, 0, 0)
            var br = obj.mapToItem(theme, obj.width, obj.height)
            return { "x": tl.x, "y": tl.y, "w": br.x - tl.x, "h": br.y - tl.y,
                     "cx": (tl.x + br.x) / 2, "cy": (tl.y + br.y) / 2,
                     "right": br.x, "bottom": br.y, "obj": obj }
        }

        // 0.5 logical px per d44 §6 case 2, plus float rounding slack.
        function close(actual, expected, what, tol) {
            var t = tol === undefined ? 0.75 : tol
            verify(Math.abs(actual - expected) <= t,
                   what + ": actual " + actual + " vs expected " + expected)
        }

        function disabledHonesty(name) {
            var r = region(name)
            compare(r.obj.Accessible.role, Accessible.Button, name + " has a button role")
            verify(r.obj.opacity < 1, name + " must be visibly unavailable (dimmed)")
            verify(r.obj.visible, name + " must remain visible")
            var acc = r.obj.Accessible ? r.obj.Accessible.name : ""
            verify(acc.indexOf("unavailable") !== -1 || acc.indexOf("not yet implemented") !== -1,
                   name + " must carry an honest unavailable description")
        }

        function test_unavailable_controls_data() {
            return [
                {tag: "Macintosh", filename: "Macintosh.qml", controls: []},
                {tag: "Windows7", filename: "Windows7.qml",
                 controls: ["switchUser", "sessionPill", "restartAction", "shutdownAction"]},
                {tag: "MaterialYou", filename: "MaterialYou.qml",
                 controls: ["userPill", "powerTile", "sessionTile", "rebootTile", "sleepTile"]},
                {tag: "Enfield", filename: "Enfield.qml",
                 controls: ["userName", "sessionAffordance", "restartAction", "shutdownAction"]},
                {tag: "Clockwork", filename: "Clockwork.qml",
                 controls: ["userSelector", "sessionAction", "rebootAction", "shutdownAction"]}
            ]
        }

        function test_unavailable_controls(data) {
            load(data.filename)
            for (var i = 0; i < data.controls.length; i++)
                disabledHonesty(data.controls[i])
        }

        // ---- Windows7 ----
        function test_windows7_geometry() {
            load("Windows7.qml")
            var s = 800 / 768

            var frame = region("pfpFrame")
            close(frame.w, 132 * s, "win7 avatar frame width")
            close(frame.h, 132 * s, "win7 avatar frame height")
            close(frame.cx, 1280 / 2, "win7 avatar frame centered")

            var field = region("fieldFrame")
            close(field.cx, 1280 / 2, "win7 FIELD is centered (not the group)")
            close(field.w, 240 * s, "win7 field width")
            close(field.h, 28 * s, "win7 field height")

            var arrow = region("submitArrow")
            close(arrow.x, field.right + 8 * s, "win7 arrow attached 8s beyond the field's right edge")
            close(arrow.w, 28 * s, "win7 arrow size")
            close(arrow.cy, field.cy, "win7 arrow shares the field's centerline")

            var su = region("switchUser")
            close(su.cx, 1280 / 2, "win7 Switch User centered")
            close(su.h, 26 * s, "win7 Switch User height")
            disabledHonesty("switchUser")

            var footer = region("footerBar")
            close(footer.h, 52 * s, "win7 footer height")
            close(footer.y + footer.h, 800, "win7 footer at the bottom edge")
            verify(region("sessionRow").x < region("clockRow").x, "win7 session left of clock")
            verify(region("powerRow").x > region("clockRow").x, "win7 power right of clock")
            close(region("clockRow").cx, 1280 / 2, "win7 footer clock centered")
        }

        function test_windows7_narrow_stacks_footer() {
            load("Windows7.qml", 492, 768)
            var clock = region("clockRow")
            var session = region("sessionRow")
            var power = region("powerRow")
            verify(clock.y > session.y, "narrow: clock drops to the second row")
            verify(Math.abs(session.y - power.y) < 1, "narrow: session and power share the top row")
            var footer = region("footerBar")
            verify(footer.h > 52, "narrow: the footer grows instead of overlapping")
        }

        function test_windows7_status_and_placeholder() {
            load("Windows7.qml")
            var status = region("statusText").obj
            verify(status.visible, "win7 status region renders the initial prompt")
            compare(status.text, ctx.auth.status)
            var before = status.height
            ctx.auth.status = "D44 challenge: a long multi-line verification code prompt that must wrap rather than clip"
            ctx.auth.isError = false
            tryVerify(function () { return status.height > before }, 1000,
                      "win7 status grows for a long real message")
        }

        // ---- MaterialYou ----
        function test_materialyou_geometry() {
            load("MaterialYou.qml")
            var s = 800 / 768

            var group = region("group")
            close(group.cx, 1280 / 2, "material group centered")
            var left = region("clockCol")
            var right = region("rightCol")
            close(right.x - (left.x + left.w), 96 * s, "material column gap")

            var card = region("card")
            close(card.w, 376 * s, "material card width")
            verify(card.h >= 180 * s, "material card nominal height")
            var field = region("fieldFrame")
            close(field.w, 336 * s, "material field width")
            close(field.h, 52 * s, "material field height")

            var gridObj = region("settingsGrid").obj
            verify(gridObj.children.length >= 4, "material: four settings tiles")
            var tile = gridObj.children[0]
            close(tile.width, 180 * s, "material tile width")
            close(tile.height, 76 * s, "material tile height")

            var unlock = region("unlockPill")
            close(unlock.h, 38 * s, "material unlock pill height")
            var user = region("userPill")
            close(user.h, 38 * s, "material user pill height")
            disabledHonesty("userPill")
            for (var i = 0; i < gridObj.children.length; i++)
                verify(gridObj.children[i].opacity < 1, "material tile " + i + " visibly unavailable")
        }

        function test_materialyou_narrow_stacks() {
            load("MaterialYou.qml", 492, 768)
            var left = region("clockCol")
            var right = region("rightCol")
            verify(right.y > left.y, "material narrow: groups stack vertically")
            close(left.cx, 492 / 2, "material narrow: clock group centered")
            close(right.cx, 492 / 2, "material narrow: settings group centered")
        }

        function test_materialyou_card_grows_for_real_messages() {
            load("MaterialYou.qml")
            var cardObj = region("card").obj
            var atRest = cardObj.height
            ctx.auth.isError = true
            ctx.auth.status = "D44 verification: the one-time code was rejected; contact your administrator for a long multi-line instruction block"
            tryVerify(function () { return cardObj.height > atRest }, 1000,
                      "material card grows for a wrapped real message")
        }

        // d45: the flake that retired the comparison gate was a live-date
        // text width moving the reference's centered group. Our side must
        // be structurally immune: the centered group's geometry is a pure
        // function of the viewport, never of rendered date/time text.
        // This pins the invariant with the repo's own harness — if it ever
        // drifts, the fix is structural, not a tolerance.
        function test_materialyou_group_is_content_independent() {
            load("MaterialYou.qml")
            // Pin the clock: LockContext's 1 Hz tick would otherwise
            // overwrite `now` mid-measurement. Test-only reach-in.
            ctx._clockTimer.stop()
            var variants = [
                new Date(2026, 8, 27, 9, 5),     // Sunday, Sep 27 — 09:05
                new Date(2026, 11, 23, 22, 58),  // Wednesday, Dec 23 — 22:58
                new Date(2026, 0, 1, 0, 0)       // Thursday, Jan 1 — 00:00
            ]
            var baseline = null
            for (var i = 0; i < variants.length; i++) {
                ctx.clock.now = variants[i]
                waitForRendering(theme)
                var g = region("group")
                if (baseline === null) {
                    baseline = g
                    continue
                }
                compare(g.cx, baseline.cx,
                        "material group cx is date/time-content independent")
                compare(g.w, baseline.w,
                        "material group width is date/time-content independent")
            }
        }

        // ---- Enfield ----
        function test_enfield_geometry() {
            load("Enfield.qml")
            var s = 800 / 768

            var clock = region("clockCol")
            close(clock.x, 64 * s, "enfield clock left margin")
            close(clock.y, 55 * s, "enfield clock top margin")

            var col = region("authColumn")
            close(col.w, 360 * s, "enfield auth column width")
            close(col.cx, 1280 / 2, "enfield auth column centered")
            close(col.y + col.h, 800 - 110 * s, "enfield auth column bottom margin")

            var pill = region("fieldPill")
            close(pill.h, 48 * s, "enfield field pill height")
            close(pill.w, col.w, "enfield field pill fills the column")

            var arrow = region("submitArrow")
            close(arrow.w, 34 * s, "enfield submit circle size")
            close(arrow.right, pill.right - 8 * s, "enfield submit inset 8s from the pill's right edge")
            verify(arrow.cy > pill.y && arrow.cy < pill.bottom, "enfield submit inside the pill vertically")

            var sep = region("footerSeparator")
            close(sep.w, 1280 - 80 * s, "enfield footer separator width")
            close(sep.bottom, 800 - 40 * s, "enfield footer separator position")
            verify(region("footerBar").h > 0, "enfield footer bar present")
            disabledHonesty("sessionAffordance")
        }

        // ---- Clockwork / Orbital ----
        function test_clockwork_relationships() {
            load("Clockwork.qml")
            var s = 800 / 768

            var container = region("clockContainer")
            var pill = region("readingPill")
            close(pill.w, 330 * s, "orbital pill width")
            close(pill.h, 90 * s, "orbital pill height")
            close(pill.x - container.x, 270 * s, "orbital pill at cx + 230s")
            close(pill.cy - container.y, container.h / 2, "orbital pill on the vertical axis")

            var hour = region("hourText")
            close(pill.x - hour.right, 40 * s, "orbital hour 40s left of the pill")

            var date = region("dateColumn")
            close(date.x - (pill.x + pill.w), 110 * s, "orbital date right of the pill")
            close(date.cy - container.y, container.h / 2, "orbital date on the vertical axis")

            var auth = region("authColumn")
            close(auth.w, 350 * s, "orbital auth width")
            close(1280 - (auth.x + auth.w), 80 * s, "orbital auth right margin")
            close(800 - (auth.y + auth.h), 80 * s, "orbital auth bottom margin")
        }

        function test_clockwork_scale_axis_exact() {
            load("Clockwork.qml")
            var s = 800 / 768
            // Deterministic: stop the context's 1 Hz ticker, pin the time,
            // let interpolation settle, measure.
            ctx._clockTimer.stop()
            ctx.clock.now = new Date(2026, 8, 26, 6, 25, 0, 0)
            wait(700)

            // Minute-25 label sits at the reading axis: (cx + nRad, cy).
            var expectX = 40 * s + (320 - 35) * s
            var expectY = 800 / 2
            var labels = []
            collectScaleLabels(theme, 22 * s, "25", labels)
            // The sharp and soft layers co-locate the label at the axis.
            verify(labels.length >= 1, "minute-scale 25 label present")
            var center = labels[0].mapToItem(theme, labels[0].width / 2, labels[0].height / 2)
            verify(Math.abs(center.x - expectX) < 2, "minute 25 label on the reading axis (x)")
            verify(Math.abs(center.y - expectY) < 2, "minute 25 label on the reading axis (y)")
        }

        function collectScaleLabels(item, pixelSize, text, out) {
            for (var i = 0; i < item.children.length; i++) {
                var c = item.children[i]
                if (c && c.font && Math.abs(c.font.pixelSize - pixelSize) < 0.5
                        && c.text === text && c.visible)
                    out.push(c)
                collectScaleLabels(c, pixelSize, text, out)
            }
        }

        function test_clockwork_narrow() {
            load("Clockwork.qml", 492, 768)
            // The intact hour..pill group is centered (the pill alone is
            // right of center: the hour sits to its left). The Outfit face
            // loads asynchronously and changes the hour's width, so the
            // centering settles a moment after load — wait for it.
            tryVerify(function () {
                var h = region("hourText")
                var p = region("readingPill")
                return Math.abs((h.x + p.right) / 2 - 492 / 2) <= 2.5
            }, 1500, "orbital narrow: hour..pill group centered")
            var pill = region("readingPill")
            var date = region("dateColumn")
            verify(date.y > pill.y + pill.h - 1, "orbital narrow: date below the pill")
            // The auth column centers independently of the font settle.
            close(region("authColumn").cx, 492 / 2, "orbital narrow: auth centered", 2.5)
        }

        // ---- Regression: unchanged d43 surfaces ----
        function test_macintosh_unchanged_structure() {
            load("Macintosh.qml")
            // d44 does not touch Macintosh: it still cold-loads, exposes the
            // focus hook, and embeds exactly one shared input core.
            verify(typeof theme.focusInput === "function", "macintosh focus hook")
            var cores = []
            collectCores(theme, cores)
            compare(cores.length, 1, "macintosh embeds exactly one AuthField core")
        }

        function collectCores(item, out) {
            for (var i = 0; i < item.children.length; i++) {
                var c = item.children[i]
                if (c && typeof c.focusField === "function" && c.hasActiveFocus !== undefined)
                    out.push(c)
                collectCores(c, out)
            }
        }
    }
}
