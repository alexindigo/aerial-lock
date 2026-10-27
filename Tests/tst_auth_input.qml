import QtQuick
import QtTest
import "../Services" as Services
import "../Modules/Lock" as LockModule

// d43 shared-auth-input suite: the AuthInputState model contract and the
// AuthField core synchronization, handoff, tuning and lifecycle behavior.
// Synthetic strings only; no real credentials ever enter a test.
Item {
    id: root
    width: 640
    height: 480

    Component {
        id: contextComponent
        Services.LockContext {}
    }

    Component {
        id: fieldComponent
        LockModule.AuthField {
            width: 200
            height: 40
        }
    }

    Component {
        id: styledFieldComponent
        LockModule.AuthField {
            width: 200
            height: 40
            // Every d44 presentation seam exercised at once.
            fontFamily: "DejaVu Sans"
            fontWeight: Font.Bold
            fontLetterSpacing: 2
            horizontalAlignment: TextInput.AlignHCenter
            maskCharacter: "✦"
            cursorDelegate: Rectangle {
                width: 2
                height: 18
                color: "#ff00ff"
            }
        }
    }

    TestCase {
        name: "AuthInputStateModel"
        when: windowShown

        property var ctx: null
        property var model: null

        function init() {
            ctx = createTemporaryObject(contextComponent, root)
            model = ctx.auth.input
        }

        function test_initial_state() {
            compare(model.text, "")
            compare(model.cursorPosition, 0)
            compare(model.anchorPosition, 0)
            compare(model.revision, 0)
            compare(model.activeWriter, -1)
            compare(model.handoffState, "")
            compare(model.effectivePolicy, model.policyPreserve)
            compare(model.effectiveScope, model.scopeLock)
            verify(model.initialWindowOpen)
            verify(!model.tuningLatched)
        }

        function test_register_unique_tokens() {
            var a = model.registerWriter()
            var b = model.registerWriter()
            verify(a !== b)
            verify(a > 0 && b > 0)
        }

        function test_claim_single_active() {
            var a = model.registerWriter()
            var b = model.registerWriter()
            verify(model.claimWriter(a))
            compare(model.activeWriter, a)
            verify(!model.claimWriter(b), "second writer cannot claim while active")
            compare(model.activeWriter, a)
        }

        function test_applyEdit_guards() {
            var a = model.registerWriter()
            var b = model.registerWriter()
            model.claimWriter(a)
            // Wrong token rejected.
            verify(!model.applyEdit(b, model.revision, "x", 1, 1))
            compare(model.text, "")
            // Stale base revision rejected.
            verify(model.applyEdit(a, model.revision, "ab", 2, 2))
            verify(!model.applyEdit(a, 0, "ab!", 3, 3))
            compare(model.text, "ab")
            // Coherent publish + clamping.
            verify(model.applyEdit(a, model.revision, "ab", 99, -3))
            compare(model.text, "ab")
            compare(model.cursorPosition, 2)
            compare(model.anchorPosition, 0)
        }

        function test_setSelection_directional() {
            var a = model.registerWriter()
            model.claimWriter(a)
            model.applyEdit(a, model.revision, "abcdef", 6, 6)
            // Reverse selection: anchor 6, caret 3.
            verify(model.setSelection(a, model.revision, 3, 6))
            compare(model.cursorPosition, 3)
            compare(model.anchorPosition, 6)
            compare(model.selectionStart, 3)
            compare(model.selectionEnd, 6)
            // Forward and collapsed.
            verify(model.setSelection(a, model.revision, 5, 2))
            compare(model.anchorPosition, 2)
            compare(model.cursorPosition, 5)
            verify(model.setSelection(a, model.revision, 4, 4))
            compare(model.selectionStart, 4)
            compare(model.selectionEnd, 4)
            // Wrong token cannot move the caret.
            var b = model.registerWriter()
            verify(!model.setSelection(b, model.revision, 0, 0))
            compare(model.cursorPosition, 4)
        }

        function test_consume_clears_and_returns() {
            var a = model.registerWriter()
            model.claimWriter(a)
            model.applyEdit(a, model.revision, "secret-synthetic", 3, 1)
            var rev = model.revision
            var draft = model.consume()
            compare(draft, "secret-synthetic")
            compare(model.text, "")
            compare(model.cursorPosition, 0)
            compare(model.anchorPosition, 0)
            verify(model.revision > rev)
        }

        function test_clear_is_not_a_response_boundary() {
            var a = model.registerWriter()
            model.claimWriter(a)
            model.applyEdit(a, model.revision, "ab", 2, 2)
            model.clear()
            compare(model.text, "")
            // The edit closed the window; clear() must not have reopened it
            // (tuning progress is preserved across an explicit clear).
            verify(!model.initialWindowOpen)
        }

        function test_offerTunings_latch() {
            var a = model.registerWriter()
            var b = model.registerWriter()
            model.claimWriter(a)
            model.offerTunings(a, model.policyIgnoreLeading, model.scopeResponse)
            compare(model.effectivePolicy, model.policyIgnoreLeading)
            compare(model.effectiveScope, model.scopeResponse)
            // Non-active writer cannot change tunings.
            model.offerTunings(b, model.policyPreserve, model.scopeLock)
            compare(model.effectivePolicy, model.policyIgnoreLeading)
            // Any interaction latches; later offers are ignored.
            model.noteInteraction(a)
            verify(model.tuningLatched)
            model.offerTunings(a, model.policyPreserve, model.scopeLock)
            compare(model.effectivePolicy, model.policyIgnoreLeading)
        }

        function test_filter_preserve() {
            var a = model.registerWriter()
            model.claimWriter(a)
            model.offerTunings(a, model.policyPreserve, model.scopeLock)
            verify(!model.filterInitialSpace(a, false))
            verify(!model.filterInitialSpace(a, true))
        }

        function test_filter_ignoreFirst() {
            var a = model.registerWriter()
            model.claimWriter(a)
            model.offerTunings(a, model.policyIgnoreFirst, model.scopeLock)
            // Initial Space press consumed; its autorepeats consumed until
            // release; a later intentional Space inserts.
            verify(model.filterInitialSpace(a, false))
            verify(model.ignoredPressActive)
            verify(model.filterInitialSpace(a, true), "repeat of the ignored press")
            model.noteInitialSpaceRelease(a)
            verify(!model.ignoredPressActive)
            verify(!model.filterInitialSpace(a, false), "later Space is not consumed")
            // An autorepeat with no ignored press is not consumed.
            verify(!model.filterInitialSpace(a, true))
        }

        function test_filter_ignoreFirst_edit_closes_window() {
            var a = model.registerWriter()
            model.claimWriter(a)
            model.offerTunings(a, model.policyIgnoreFirst, model.scopeLock)
            // First eligible editing key is not Space: apply, window closes.
            model.applyEdit(a, model.revision, "x", 1, 1)
            verify(!model.filterInitialSpace(a, false), "Space after an edit is not initial")
        }

        function test_filter_ignoreLeading() {
            var a = model.registerWriter()
            model.claimWriter(a)
            model.offerTunings(a, model.policyIgnoreLeading, model.scopeLock)
            verify(model.filterInitialSpace(a, false))
            verify(model.filterInitialSpace(a, false), "repeated presses while open")
            verify(model.filterInitialSpace(a, true), "autorepeat while open")
            // Accepted text insertion closes the window.
            model.applyEdit(a, model.revision, "x", 1, 1)
            verify(!model.filterInitialSpace(a, false))
            // Deleting back to empty does not reopen it.
            model.applyEdit(a, model.revision, "", 0, 0)
            verify(!model.filterInitialSpace(a, false), "no retroactive reopening")
        }

        function test_response_scope_resets_on_consume() {
            var a = model.registerWriter()
            model.claimWriter(a)
            model.offerTunings(a, model.policyIgnoreLeading, model.scopeResponse)
            model.noteInteraction(a)
            verify(model.filterInitialSpace(a, false))
            model.applyEdit(a, model.revision, "pw", 2, 2)
            verify(!model.initialWindowOpen)
            model.consume()
            verify(model.initialWindowOpen, "new empty editable response reopens")
            verify(!model.tuningLatched, "new epoch accepts tuning offers")
        }

        function test_lock_scope_never_resets_mid_lock() {
            var a = model.registerWriter()
            model.claimWriter(a)
            model.offerTunings(a, model.policyIgnoreLeading, model.scopeLock)
            model.noteInteraction(a)
            model.applyEdit(a, model.revision, "pw", 2, 2)
            model.consume()
            verify(!model.initialWindowOpen, "lock scope: consume is not a reset")
            verify(model.tuningLatched)
        }

        function test_handoff_state_machine() {
            var spyDone = createTemporaryObject(spyComponent, root, { "target": model, "signalName": "handoffCompleted" })
            var spyAbort = createTemporaryObject(spyComponent, root, { "target": model, "signalName": "handoffAborted" })
            var a = model.registerWriter()
            var b = model.registerWriter()
            model.claimWriter(a)
            model.applyEdit(a, model.revision, "draft", 5, 5)
            var gen = model.generation

            model.requestHandoff()
            compare(model.handoffState, "releasing")
            // The outgoing editor flushes (already coherent here) and releases.
            verify(model.releaseWriter(a))
            compare(model.activeWriter, -1)
            compare(model.handoffState, "awaitingClaim")
            verify(model.generation > gen)
            // The old writer can no longer publish.
            verify(!model.applyEdit(a, model.revision, "stale", 5, 5))
            compare(model.text, "draft")
            // The incoming editor claims mid-handoff.
            verify(model.claimHandoff(b))
            compare(model.activeWriter, b)
            compare(model.handoffState, "")
            compare(spyDone.count, 1)
            compare(spyAbort.count, 0)
            compare(model.text, "draft", "handoff preserves the draft")
        }

        function test_handoff_abort_recovers() {
            var spyAbort = createTemporaryObject(spyComponent, root, { "target": model, "signalName": "handoffAborted" })
            var a = model.registerWriter()
            model.claimWriter(a)
            model.applyEdit(a, model.revision, "keepme", 6, 6)
            model.requestHandoff()
            verify(model.releaseWriter(a))
            model.abortHandoff()
            compare(model.handoffState, "")
            compare(spyAbort.count, 1)
            compare(model.text, "keepme", "abort never clears the draft")
            // The released editor can re-claim the idle model.
            verify(model.claimWriter(a))
        }

        function test_requestHandoff_without_active_writer() {
            compare(model.activeWriter, -1)
            model.requestHandoff()
            compare(model.handoffState, "awaitingClaim")
            var b = model.registerWriter()
            verify(model.claimHandoff(b))
            compare(model.activeWriter, b)
        }

        function test_activity_and_readiness() {
            var a = model.registerWriter()
            model.claimWriter(a)
            verify(model.handoffReady)
            model.setActivity(a, true, false)
            verify(model.compositionActive)
            verify(!model.handoffReady)
            var b = model.registerWriter()
            model.setActivity(b, false, false)
            verify(model.compositionActive, "inactive writer cannot report activity")
            model.setActivity(a, false, false)
            verify(model.handoffReady)
        }
    }

    Component {
        id: spyComponent
        SignalSpy {}
    }

    TestCase {
        id: coreCase
        name: "AuthFieldCore"
        when: windowShown

        property var ctx: null
        property var model: null
        property int submitCount: 0
        property int rejectedCount: 0
        property var accepted: []

        Connections {
            id: submitSpy
            // Mimics Lock.qml's zero-argument acceptance: busy submissions
            // are rejected without touching the draft; accepted submissions
            // consume exactly once. Handlers run in the Connections' own
            // scope: TestCase properties need the explicit id (probe-verified).
            function onSubmitRequested() {
                if (coreCase.ctx.auth.inProgress) {
                    coreCase.rejectedCount++
                    return
                }
                coreCase.accepted.push(coreCase.model.consume())
                coreCase.submitCount++
            }
        }

        function init() {
            ctx = createTemporaryObject(contextComponent, root)
            model = ctx.auth.input
            submitSpy.target = ctx
            submitCount = 0
            rejectedCount = 0
            accepted = []
        }

        function acceptedIs(list) {
            if (accepted.length !== list.length)
                return false
            for (var i = 0; i < list.length; i++)
                if (accepted[i] !== list[i])
                    return false
            return true
        }

        function mkfield(props, comp) {
            var base = { "context": ctx }
            if (props)
                for (var k in props)
                    base[k] = props[k]
            return createTemporaryObject(comp || fieldComponent, root, base)
        }

        function focused(field) {
            field.focusField()
            tryVerify(function () { return field.hasActiveFocus }, 1000,
                      "field did not gain active focus")
        }

        function test_typing_publishes_coherently() {
            var f = mkfield()
            focused(f)
            keyClick(Qt.Key_A)
            keyClick(Qt.Key_B)
            keyClick(Qt.Key_C)
            compare(model.text, "abc")
            compare(model.cursorPosition, 3)
            compare(model.anchorPosition, 3)
            // Caret into the middle, insert: model and view agree.
            keyClick(Qt.Key_Left)
            keyClick(Qt.Key_Left)
            tryVerify(function () { return model.cursorPosition === 1 }, 1000)
            keyClick(Qt.Key_X)
            compare(model.text, "axbc")
            compare(model.cursorPosition, 2)
            compare(model.anchorPosition, 2)
            // Backspace removes the char before the caret; Delete at it.
            keyClick(Qt.Key_Backspace)
            compare(model.text, "abc")
            compare(model.cursorPosition, 1)
            keyClick(Qt.Key_Delete)
            compare(model.text, "ac")
            compare(model.cursorPosition, 1)
        }

        function test_selection_moves_publish() {
            var f = mkfield()
            focused(f)
            keyClick(Qt.Key_A)
            keyClick(Qt.Key_B)
            keyClick(Qt.Key_C)
            keyClick(Qt.Key_Left, Qt.ShiftModifier)
            tryVerify(function () {
                return model.cursorPosition === 2 && model.anchorPosition === 3
            }, 1000, "shift-selection did not reach the model")
            compare(model.selectionStart, 2)
            compare(model.selectionEnd, 3)
            // Collapse back with a plain arrow: native behavior collapses
            // the selection to its left edge (selectionStart), no skip.
            keyClick(Qt.Key_Left)
            tryVerify(function () {
                return model.cursorPosition === 2 && model.anchorPosition === 2
            }, 1000, "collapsed caret move did not reach the model")
        }

        function test_directional_selection_survives_handoff() {
            var a = mkfield()
            focused(a)
            keyClick(Qt.Key_A)
            keyClick(Qt.Key_B)
            keyClick(Qt.Key_C)
            keyClick(Qt.Key_D)
            keyClick(Qt.Key_E)
            keyClick(Qt.Key_F)
            keyClick(Qt.Key_Left, Qt.ShiftModifier)
            keyClick(Qt.Key_Left, Qt.ShiftModifier)
            keyClick(Qt.Key_Left, Qt.ShiftModifier)
            tryVerify(function () {
                return model.cursorPosition === 3 && model.anchorPosition === 6
            }, 1000, "reverse selection not published")

            var b = mkfield({ "visible": false })
            verify(model.activeWriter !== b._token)
            model.requestHandoff()
            tryVerify(function () { return model.activeWriter === b._token },
                      1000, "incoming editor did not claim the handoff")
            compare(model.text, "abcdef")
            compare(model.cursorPosition, 3)
            compare(model.anchorPosition, 6)
            // Promotion makes the claimed editor visible (ThemeHost's role).
            b.visible = true
            // Typing in the hydrated editor replaces the PRESERVED reverse
            // selection (3..6 -> "def"), proving directional hydration.
            focused(b)
            keyClick(Qt.Key_Y)
            compare(model.text, "abcy")
        }

        function test_hidden_candidate_never_publishes() {
            var a = mkfield()
            focused(a)
            keyClick(Qt.Key_A)
            keyClick(Qt.Key_B)
            compare(model.text, "ab")
            var b = mkfield({ "visible": false })
            // The hidden candidate registered but is not active, and its
            // empty native field must not initialize or erase the draft.
            verify(model.activeWriter !== b._token)
            compare(model.text, "ab")
            // A stale callback with the wrong token is rejected.
            verify(!model.applyEdit(b._token, model.revision, "", 0, 0))
            compare(model.text, "ab")
            b.destroy()
            compare(model.text, "ab", "candidate destruction does not clear the draft")
        }

        function test_destroy_active_releases_but_preserves() {
            var a = mkfield()
            focused(a)
            keyClick(Qt.Key_A)
            keyClick(Qt.Key_B)
            compare(model.text, "ab")
            var oldToken = a._token
            a.destroy()
            compare(model.text, "ab", "widget destruction never clears the draft")
            tryVerify(function () { return model.activeWriter === -1 }, 1000,
                      "destroyed editor did not release authority")
            verify(!model.applyEdit(oldToken, model.revision, "zz", 2, 2),
                   "the destroyed writer's token is dead")
            var b = mkfield()
            focused(b)
            keyClick(Qt.Key_C)
            compare(model.text, "abc", "a new editor resumes the preserved draft")
        }

        function test_submit_consumes_once_and_mirrors_clear() {
            var a = mkfield()
            focused(a)
            keyClick(Qt.Key_A)
            keyClick(Qt.Key_B)
            keyClick(Qt.Key_C)
            compare(model.text, "abc")
            keyClick(Qt.Key_Return)
            compare(submitCount, 1)
            verify(acceptedIs(["abc"]))
            tryVerify(function () { return model.text === "" }, 1000)
            compare(model.cursorPosition, 0)
            // Submitted text is not resurrectable through native undo.
            keyClick(Qt.Key_Z, Qt.ControlModifier)
            tryVerify(function () { return model.text === "" }, 500)
            compare(submitCount, 1, "undo must not produce a new submission")
        }

        function test_busy_submit_rejected_preserving_draft() {
            var a = mkfield()
            focused(a)
            keyClick(Qt.Key_A)
            keyClick(Qt.Key_B)
            ctx.auth.inProgress = true
            keyClick(Qt.Key_Return)
            compare(submitCount, 0, "busy field must not even request")
            compare(model.text, "ab")
            // A custom caller hitting the context directly is rejected by
            // the controller without changing the draft either.
            ctx.auth.submit()
            compare(rejectedCount, 1)
            compare(model.text, "ab")
            ctx.auth.inProgress = false
            keyClick(Qt.Key_Return)
            compare(submitCount, 1)
            verify(acceptedIs(["ab"]))
        }

        function test_keypad_enter_shares_submission_path() {
            var a = mkfield()
            focused(a)
            keyClick(Qt.Key_Q)
            keyClick(Qt.Key_Enter)
            compare(submitCount, 1)
            verify(acceptedIs(["q"]))
        }

        function test_public_submit_button_path() {
            var a = mkfield()
            focused(a)
            keyClick(Qt.Key_W)
            a.submit()
            compare(submitCount, 1)
            verify(acceptedIs(["w"]))
        }

        function test_space_policy_ignoreLeading_core() {
            var a = mkfield({ "initialSpacePolicy": model.policyIgnoreLeading })
            focused(a)
            keyClick(Qt.Key_Space)
            keyClick(Qt.Key_Space)
            compare(model.text, "", "leading Spaces consumed before first insertion")
            // Modified Space is native handling: not consumed, inserts
            // nothing, does not close the window.
            keyClick(Qt.Key_Space, Qt.ControlModifier)
            keyClick(Qt.Key_Space)
            compare(model.text, "", "unmodified Space still initial after Ctrl+Space")
            keyClick(Qt.Key_N)
            compare(model.text, "n")
            keyClick(Qt.Key_Space)
            compare(model.text, "n ", "Space after accepted insertion is kept")
        }

        function test_space_policy_ignoreFirst_core() {
            var a = mkfield({ "initialSpacePolicy": model.policyIgnoreFirst })
            focused(a)
            keyClick(Qt.Key_Space)
            compare(model.text, "", "initial Space consumed")
            keyClick(Qt.Key_Space)
            compare(model.text, " ", "a later intentional Space is inserted")
        }

        function test_space_policy_preserve_default() {
            var a = mkfield()
            focused(a)
            keyClick(Qt.Key_Space)
            compare(model.text, " ", "preserve: no suppression")
            compare(model.effectivePolicy, model.policyPreserve)
        }

        function test_handoff_preserves_draft_mid_typing() {
            var a = mkfield()
            focused(a)
            keyClick(Qt.Key_P)
            keyClick(Qt.Key_R)
            keyClick(Qt.Key_E)
            compare(model.text, "pre")
            var b = mkfield({ "visible": false })
            model.requestHandoff()
            tryVerify(function () { return model.activeWriter === b._token }, 1000)
            b.visible = true
            focused(b)
            keyClick(Qt.Key_F)
            keyClick(Qt.Key_I)
            keyClick(Qt.Key_X)
            compare(model.text, "prefix", "prefix typed before promotion plus suffix after")
            keyClick(Qt.Key_Return)
            verify(acceptedIs(["prefix"]))
        }

        function test_error_and_busy_changes_preserve_draft() {
            var a = mkfield()
            focused(a)
            keyClick(Qt.Key_A)
            keyClick(Qt.Key_B)
            ctx.auth.isError = true
            ctx.auth.status = "Authentication failed"
            ctx.auth.inProgress = true
            ctx.auth.inProgress = false
            compare(model.text, "ab", "status/busy changes never consume an unsubmitted draft")
        }

        function test_known_response_limit_cap() {
            ctx.auth.maxResponseSize = 5
            var a = mkfield()
            focused(a)
            keyClick(Qt.Key_A)
            keyClick(Qt.Key_B)
            keyClick(Qt.Key_C)
            keyClick(Qt.Key_D)
            keyClick(Qt.Key_E)
            keyClick(Qt.Key_F)
            compare(model.text, "abcd", "cap is maxResponseSize - 1")
            compare(model.cursorPosition, 4)
            // Deletion then more typing still agrees at the boundary.
            keyClick(Qt.Key_Backspace)
            keyClick(Qt.Key_Z)
            compare(model.text, "abcz")
        }

        function test_unknown_limit_uses_widget_ceiling() {
            ctx.auth.maxResponseSize = 0
            var a = mkfield()
            focused(a)
            keyClick(Qt.Key_A)
            keyClick(Qt.Key_B)
            compare(model.text, "ab")
        }

        // d44 phase 2: all presentation seams set at once must not mutate
        // draft, selection, writer or tuning progress.
        function test_presentation_seams_do_not_mutate_state() {
            var f = mkfield(null, styledFieldComponent)
            focused(f)
            var writer = model.activeWriter
            verify(writer > 0)
            keyClick(Qt.Key_A)
            keyClick(Qt.Key_B)
            keyClick(Qt.Key_C)
            compare(model.text, "abc")
            compare(model.activeWriter, writer, "styling must not churn writer authority")
            keyClick(Qt.Key_Left, Qt.ShiftModifier)
            tryVerify(function () {
                return model.cursorPosition === 2 && model.anchorPosition === 3
            }, 1000, "selection under full styling did not reach the model")
            // The default tuning profile is preserve: the accepted
            // insertions above closed the initial-input window exactly as
            // an unstyled field's would.
            verify(!model.initialWindowOpen, "accepted insertion closes the window")
            // The selection is live: typing Space replaces the selected
            // 'c', like any native editor under any styling.
            keyClick(Qt.Key_Space)
            compare(model.text, "ab ")
            compare(model.activeWriter, writer)
            keyClick(Qt.Key_Return)
            verify(acceptedIs(["ab "]))
            tryVerify(function () { return model.text === "" }, 1000)
            compare(model.activeWriter, writer, "authority survives consume")
        }

        function test_tunings_latch_across_editors() {
            var a = mkfield({ "initialSpacePolicy": model.policyIgnoreLeading })
            focused(a)
            keyClick(Qt.Key_Space)
            compare(model.text, "")
            verify(model.tuningLatched, "even an ignored Space is interaction")
            // A promoted theme offering different tunings cannot change the
            // effective profile halfway through the epoch.
            var b = mkfield({ "visible": false, "initialSpacePolicy": model.policyPreserve })
            model.requestHandoff()
            tryVerify(function () { return model.activeWriter === b._token }, 1000)
            compare(model.effectivePolicy, model.policyIgnoreLeading)
            b.visible = true
            focused(b)
            keyClick(Qt.Key_Space)
            compare(model.text, "", "latched profile still filters")
        }
    }
}
