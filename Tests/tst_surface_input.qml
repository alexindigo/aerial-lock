import QtQuick
import QtTest
import "../Services" as Services
import "../Modules/Lock" as LockModule

Item {
    id: root
    width: 640
    height: 480

    Component { id: contextComponent; Services.LockContext {} }
    Component {
        id: surfacesComponent
        Item {
            id: rig
            required property Services.LockContext context
            property alias panel: panel
            property alias sink: sink
            Item {
                width: 320; height: 480
                LockModule.AuthField {
                    id: panel
                    objectName: "surfacePanelField"
                    context: rig.context
                    width: 240; height: 40
                    windowActive: false
                }
            }
            Item {
                x: 320; width: 320; height: 480
                LockModule.AuthInputSink {
                    id: sink
                    objectName: "surfaceSinkField"
                    input: rig.context.auth.input
                    inputBusy: rig.context.auth.inProgress
                    responseVisible: rig.context.auth.responseVisible
                    maxResponseSize: rig.context.auth.maxResponseSize
                    onSubmitRequested: rig.context.auth.submit()
                    width: 1; height: 1
                    opacity: 0
                    visible: false
                    windowActive: false
                }
            }
        }
    }
    Component {
        id: candidateComponent
        LockModule.AuthField {
            width: 240; height: 40
            visible: false
            windowActive: false
        }
    }

    TestCase {
        id: tests
        name: "SurfaceInput"
        when: windowShown
        property var context: null
        property var surfaces: null
        property var candidate: null
        property var accepted: []

        Connections {
            target: tests.context
            function onSubmitRequested() {
                tests.accepted.push(tests.context.auth.input.consume())
            }
        }

        function init() {
            failOnWarning(/.*/)
            context = contextComponent.createObject(root)
            surfaces = surfacesComponent.createObject(root, {context: context})
            accepted = []
            candidate = null
        }
        function cleanup() {
            if (candidate)
                candidate.destroy()
            surfaces.destroy()
            wait(0)
            context.destroy()
            wait(0)
        }
        function activate(field, old) {
            if (old)
                old.windowActive = false
            field.windowActive = true
            wait(0)
            tryVerify(function () { return field.hasActiveFocus })
        }
        function nativeInput(field) {
            var editor = findChild(field, "authNativeInput")
            verify(editor !== null)
            return editor
        }
        function test_non_panel_input_reaches_panel() {
            activate(surfaces.panel)
            keyClick(Qt.Key_A)
            compare(context.auth.input.text, "a")
            surfaces.sink.visible = true
            activate(surfaces.sink, surfaces.panel)
            keyClick(Qt.Key_B)
            compare(context.auth.input.text, "ab")
            var panelInput = nativeInput(surfaces.panel)
            compare(panelInput.text, "ab")
            compare(panelInput.echoMode, TextInput.Password)
            compare(panelInput.cursorPosition, 2)
            tryVerify(function () { return panelInput.cursorVisible })
        }
        function test_selection_backspace_clear_and_submit() {
            activate(surfaces.panel)
            keyClick(Qt.Key_A)
            keyClick(Qt.Key_B)
            keyClick(Qt.Key_C)
            keyClick(Qt.Key_Left, Qt.ShiftModifier)
            tryCompare(context.auth.input, "anchorPosition", 3)
            tryCompare(context.auth.input, "cursorPosition", 2)
            surfaces.sink.visible = true
            activate(surfaces.sink, surfaces.panel)
            compare(nativeInput(surfaces.sink).selectedText, "c")
            keyClick(Qt.Key_Backspace)
            compare(context.auth.input.text, "ab")
            compare(nativeInput(surfaces.panel).text, "ab")
            keyClick(Qt.Key_Return)
            compare(accepted.length, 1)
            compare(accepted[0], "ab")
            compare(nativeInput(surfaces.panel).text, "")
            compare(nativeInput(surfaces.sink).text, "")
            keyClick(Qt.Key_Z, Qt.ControlModifier)
            compare(context.auth.input.text, "")
            keyClick(Qt.Key_Q)
            context.auth.input.clear()
            compare(nativeInput(surfaces.panel).text, "")
            compare(nativeInput(surfaces.sink).text, "")
            activate(surfaces.panel, surfaces.sink)
            keyClick(Qt.Key_X)
            compare(context.auth.input.text, "x")
        }
        function test_sink_limit_echo_busy_and_no_hover_focus() {
            activate(surfaces.panel)
            surfaces.sink.visible = true
            // The unit surfaces share one QtTest window. Restore the active
            // surface's local focus after preparing the other local editor.
            surfaces.panel.focusField()
            var writer = context.auth.input.activeWriter
            mouseMove(surfaces, 330, 100)
            compare(context.auth.input.activeWriter, writer)
            verify(surfaces.panel.hasActiveFocus)
            context.auth.maxResponseSize = 3
            context.auth.responseVisible = true
            activate(surfaces.sink, surfaces.panel)
            keyClick(Qt.Key_A)
            keyClick(Qt.Key_B)
            keyClick(Qt.Key_C)
            compare(context.auth.input.text, "ab")
            compare(nativeInput(surfaces.panel).echoMode, TextInput.Normal)
            compare(nativeInput(surfaces.sink).echoMode, TextInput.Normal)
            context.auth.inProgress = true
            surfaces.sink.submit()
            compare(accepted.length, 0)
            compare(context.auth.input.text, "ab")
        }
        function test_panel_button_submits_the_active_surface_draft() {
            activate(surfaces.panel)
            surfaces.sink.visible = true
            activate(surfaces.sink, surfaces.panel)
            keyClick(Qt.Key_A)
            keyClick(Qt.Key_B)
            var writer = context.auth.input.activeWriter
            surfaces.panel.submit()
            compare(accepted.length, 1)
            compare(accepted[0], "ab")
            compare(context.auth.input.activeWriter, writer)
        }
        function test_sink_preserves_panel_initial_space_profile() {
            activate(surfaces.panel)
            var model = context.auth.input
            model.offerTunings(model.activeWriter, model.policyIgnoreLeading, model.scopeResponse)
            surfaces.sink.visible = true
            activate(surfaces.sink, surfaces.panel)
            keyClick(Qt.Key_Space)
            compare(model.text, "")
            compare(model.effectivePolicy, model.policyIgnoreLeading)
            compare(model.effectiveScope, model.scopeResponse)
            keyClick(Qt.Key_A)
            keyClick(Qt.Key_Return)
            compare(accepted.length, 1)
            keyClick(Qt.Key_Space)
            compare(model.text, "")
        }
        function test_immediate_transfer_cancels_old_gesture_and_accepts_first_keys() {
            activate(surfaces.panel)
            keyClick(Qt.Key_A)
            var model = context.auth.input
            var old = model.activeWriter
            surfaces.panel._gestureActive = true
            model.setActivity(old, false, true)
            surfaces.sink.visible = true
            surfaces.panel.windowActive = false
            surfaces.sink.windowActive = true
            compare(model.activeWriter, surfaces.sink._token)
            verify(!model.gestureActive)
            verify(!surfaces.panel._gestureActive)
            // No event-loop turn between activation and incoming keys.
            keyClick(Qt.Key_B)
            keyClick(Qt.Key_C)
            keyClick(Qt.Key_Left, Qt.ShiftModifier)
            keyClick(Qt.Key_Backspace)
            keyClick(Qt.Key_Return)
            compare(accepted.length, 1)
            compare(accepted[0], "ab")
            compare(model.text, "")
            compare(nativeInput(surfaces.panel).text, "")
        }
        function test_theme_handoff_and_focus_transfer_data() {
            return [{tag: "theme-first", themeFirst: true}, {tag: "focus-first", themeFirst: false}]
        }
        function test_fast_focus_roundtrips_preserve_every_key() {
            activate(surfaces.panel)
            var model = context.auth.input
            surfaces.sink.visible = true
            var expected = ""
            var previous = surfaces.panel
            for (var i = 0; i < 100; i++) {
                var next = i % 2 ? surfaces.panel : surfaces.sink
                previous.windowActive = false
                next.windowActive = true
                keyClick(Qt.Key_A + i % 26)
                expected += String.fromCharCode(97 + i % 26)
                compare(model.text, expected)
                compare(nativeInput(surfaces.panel).text, expected)
                previous = next
            }
        }
        function test_theme_handoff_and_focus_transfer(data) {
            activate(surfaces.panel)
            keyClick(Qt.Key_A)
            var model = context.auth.input
            var old = model.activeWriter
            // Theme promotion waits for this gesture until focus transfer
            // cancels it. Focus authority itself must never wait for promotion.
            surfaces.panel._gestureActive = true
            model.setActivity(old, false, true)
            candidate = candidateComponent.createObject(root, {context: context})
            if (data.themeFirst)
                model.requestHandoff()
            surfaces.sink.visible = true
            activate(surfaces.sink, surfaces.panel)
            keyClick(Qt.Key_B)
            if (!data.themeFirst)
                model.requestHandoff()
            tryCompare(model, "themeWriter", candidate._token)
            tryCompare(model, "activeWriter", surfaces.sink._token)
            tryCompare(model, "text", "ab")
            verify(model.themeWriter !== surfaces.sink._token)
            compare(model.handoffState, "")
            candidate.visible = true
            compare(nativeInput(candidate).text, "ab")
            // These unit surfaces share one test window. Restore its native
            // focus to represent the separate compositor-active sink window.
            surfaces.sink.focusField()
            keyClick(Qt.Key_Enter)
            compare(accepted.length, 1)
            compare(accepted[0], "ab")
        }
        function test_theme_promotes_while_sink_owns_input() {
            activate(surfaces.panel)
            surfaces.sink.visible = true
            activate(surfaces.sink, surfaces.panel)
            keyClick(Qt.Key_A)
            var model = context.auth.input
            var writer = model.activeWriter
            candidate = candidateComponent.createObject(root, {context: context})
            model.requestHandoff()
            compare(model.themeWriter, candidate._token)
            compare(model.activeWriter, writer)
            compare(model.text, "a")
            keyClick(Qt.Key_B)
            compare(model.text, "ab")
        }
    }
}
