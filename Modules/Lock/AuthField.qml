import QtQuick
import "../../Services"

// AuthField (d43) — the decoration-free shared input core. It supplies
// native text/caret rendering, editing, IME handling, masking, focus,
// response-limit enforcement and submission wiring on top of the ONE
// authoritative edit record at context.auth.input (AuthInputState). It
// draws no frame, background, border, placeholder, avatar, status label or
// surrounding layout — themes and the trusted fallback place this core
// inside their own decorations and supply bounds, padding and character
// presentation via the public properties below.
//
// Synchronization (grounded in the checkpoint-1 native characterization,
// logs/d43-shared-auth-input/checkpoint1-findings.md):
//   - Every committed native edit publishes on textEdited as a coherent
//     {text, cursor, anchor=cursor} record (edits collapse the selection).
//   - Selection-only moves publish from a one-turn coalesced flush (native
//     selection bounds are stale inside per-edit signals and settle by the
//     next event turn); submission and handoff flush synchronously.
//   - Authoritative changes (consume/clear) bump the model revision; the
//     active editor re-pulls, applying text programmatically (no textEdited,
//     native undo cleared) and restoring selection direction via
//     select(anchor, cursor).
//   - Writer token + base-revision guards: a hidden candidate or stale
//     callback can never publish, initialize the model from an empty field,
//     or restore consumed text.
//
// The root is a plain Item, NOT a FocusScope: a scope with focus:true
// captures the parent's delegation and never hands it to the field when the
// grant arrives before the child completes (d40 flake). Password contents
// never enter logging, context data beyond auth.input, diagnostics, or
// test artifacts.
Item {
    id: root

    required property LockContext context

    // Character presentation (decorations — frame, fill, border, radius,
    // height, padding — are the theme's, around this core). Selection
    // colors default to the platform palette, matching pre-d43 behavior.
    property color textColor: context.colors.input
    property color selectionColor: field.palette.highlight
    property color selectedTextColor: field.palette.highlightedText
    property int fontPixelSize: context.panel.fontSize
    // Construction-time override for the password masking glyph; empty
    // keeps Qt's platform default.
    property string maskCharacter: ""

    // d44 optional character-presentation seams. Every one defaults to
    // "unset", which leaves the native TextInput default untouched —
    // omitting them changes nothing. They are presentation only: none may
    // mutate draft, selection, writer or tuning state.
    property string fontFamily: ""          // e.g. "Segoe UI, Ubuntu, sans-serif"
    property int fontWeight: -1             // e.g. Font.Bold; -1 = native default
    property real fontLetterSpacing: -1     // px; -1 = native default
    property int horizontalAlignment: -1    // TextInput.Align*; -1 = native default
    // Draw-only custom caret; the native TextInput still positions it.
    // null keeps the native caret.
    property Component cursorDelegate: null

    function _applyPresentation() {
        if (root.fontFamily.length > 0)
            field.font.family = root.fontFamily
        if (root.fontWeight >= 0)
            field.font.weight = root.fontWeight
        if (root.fontLetterSpacing >= 0)
            field.font.letterSpacing = root.fontLetterSpacing
        if (root.horizontalAlignment >= 0)
            field.horizontalAlignment = root.horizontalAlignment
    }

    onFontFamilyChanged: _applyPresentation()
    onFontWeightChanged: _applyPresentation()
    onFontLetterSpacingChanged: _applyPresentation()
    onHorizontalAlignmentChanged: _applyPresentation()

    // Initial-space tunings offered to the context when this core becomes
    // the active editor. Effective values latch on first interaction.
    property int initialSpacePolicy: context.auth.input.policyPreserve
    property int initialSpaceScope: context.auth.input.scopeLock

    implicitWidth: 240
    implicitHeight: field.implicitHeight

    // The core paints only native input content, clipped to the bounds the
    // theme allots it: a long response scrolls horizontally inside the
    // frame instead of spilling past it (d43 case 9; the pre-d43 field
    // never clipped and overflowed).
    clip: true

    // Public behavior surface — the ONLY things a parent may call.
    function submit() {
        if (!root.visible || !root.enabled || context.auth.inProgress)
            return
        // A key used to finish a composition must not also submit to PAM.
        if (field.inputMethodComposing)
            return
        // Synchronously publish the current edit (last-key guarantee), then
        // request submission of the shared draft. The core does not clear
        // itself: the controller's consume clears every mirror.
        flush()
        context.auth.submit()
    }

    function focusField() {
        if (root.visible && root.enabled && field.enabled)
            field.forceActiveFocus()
    }
    readonly property bool hasActiveFocus: field.activeFocus

    // ---- Writer lifecycle / synchronization state ----
    property int _token: -1
    property bool _active: false
    property bool _syncing: false
    property bool _publishing: false
    property bool _releasedForHandoff: false
    property bool _selectionFlushPending: false
    property bool _gestureActive: false
    property int _appliedRevision: -1

    // Synchronously publish the native editor's full state. Safe at
    // submission/handoff: key-event records show settled state then.
    function flush() {
        if (!_active || _syncing)
            return
        var model = context.auth.input
        var cursor = field.cursorPosition
        var anchor = cursor
        var ss = field.selectionStart
        var se = field.selectionEnd
        if (ss !== se)
            anchor = (cursor === ss) ? se : ss
        root._publishing = true
        var accepted = model.applyEdit(_token, _appliedRevision, field.text, cursor, anchor)
        root._publishing = false
        if (accepted)
            _appliedRevision = model.revision
        else
            pull()
    }

    // Pull the authoritative record into the native editor (hydration and
    // post-consume/clear resync). Programmatic text assignment fires no
    // textEdited and clears the native undo stack, so submitted text is not
    // resurrectable through native undo after the authoritative clear.
    function pull() {
        var model = context.auth.input
        _syncing = true
        if (field.text !== model.text)
            field.text = model.text
        // select(anchor, cursor) preserves direction (checkpoint-1 finding 4).
        field.select(model.anchorPosition, model.cursorPosition)
        _appliedRevision = model.revision
        _syncing = false
    }

    function maybeClaim() {
        if (_active || _releasedForHandoff || _token < 0)
            return
        if (!root.visible || !root.enabled || !field.enabled)
            return
        var model = context.auth.input
        if (model.activeWriter !== -1 || model.handoffState !== "")
            return
        if (model.claimWriter(_token))
            _becameActive()
    }

    function tryClaimHandoff() {
        if (_active || _releasedForHandoff || _token < 0)
            return
        var model = context.auth.input
        if (model.handoffState !== "awaitingClaim")
            return
        if (model.claimHandoff(_token))
            _becameActive()
    }

    function _becameActive() {
        _active = true
        var model = context.auth.input
        // Offer this core's tunings before editing begins; the context
        // ignores the offer once the epoch has latched.
        model.offerTunings(_token, root.initialSpacePolicy, root.initialSpaceScope)
        // Hydrate from the authoritative record before publishing or focus.
        pull()
        model.setActivity(_token, field.inputMethodComposing, _gestureActive)
        focusField()
    }

    // Elective replacement: flush and release only when a handoff has
    // actually been requested AND no native composition or edit gesture is
    // live; otherwise defer to its natural completion (the native session
    // is never force-committed/reset). Without the handoffState gate this
    // would release authority at every composition end.
    function attemptRelease() {
        if (!_active || _releasedForHandoff)
            return
        if (context.auth.input.handoffState !== "releasing")
            return
        if (field.inputMethodComposing || _gestureActive)
            return
        flush()
        _releasedForHandoff = true
        context.auth.input.releaseWriter(_token)
        _active = false
    }

    function scheduleSelectionFlush() {
        if (!_active || _syncing || _selectionFlushPending)
            return
        _selectionFlushPending = true
        Qt.callLater(_flushSelection)
    }

    function _flushSelection() {
        _selectionFlushPending = false
        if (!_active || _syncing)
            return
        var model = context.auth.input
        if (field.text !== model.text) {
            // An authoritative change landed between turns; re-pull instead.
            if (model.revision !== _appliedRevision)
                pull()
            return
        }
        var cursor = field.cursorPosition
        var ss = field.selectionStart
        var se = field.selectionEnd
        var anchor = cursor
        if (ss !== se)
            anchor = (cursor === ss) ? se : ss
        if (cursor === model.cursorPosition && anchor === model.anchorPosition)
            return
        root._publishing = true
        var accepted = model.setSelection(root._token, root._appliedRevision, cursor, anchor)
        root._publishing = false
        if (accepted)
            root._appliedRevision = model.revision
    }

    Connections {
        target: context.auth.input
        function onRevisionChanged() {
            var model = context.auth.input
            // _publishing: my own publish must never trigger my own pull
            // (the nested pull would re-enter the native editor mid-edit,
            // including mid-input-method-event).
            if (!root._syncing && !root._publishing && root._active && model.revision !== root._appliedRevision)
                root.pull()
        }
        function onHandoffStateChanged() {
            var model = context.auth.input
            if (model.handoffState === "releasing" && root._active)
                root.attemptRelease()
            else if (model.handoffState === "awaitingClaim")
                root.tryClaimHandoff()
        }
        function onActiveWriterChanged() {
            root.maybeClaim()
        }
        function onHandoffAborted() {
            if (root._releasedForHandoff) {
                root._releasedForHandoff = false
                root.maybeClaim()
                if (root._active)
                    root.focusField()
            }
        }
    }

    Component.onCompleted: {
        _token = context.auth.input.registerWriter()
        _applyPresentation()
        if (root.maskCharacter.length > 0)
            field.passwordCharacter = root.maskCharacter
        maybeClaim()
        if (visible && enabled)
            focusField()
    }
    Component.onDestruction: {
        // Widget destruction releases authority but NEVER clears the draft.
        // The context may already be gone during teardown; then there is
        // nothing to release.
        if (_active && context !== null)
            context.auth.input.releaseWriter(_token)
    }
    onMaskCharacterChanged: {
        if (maskCharacter.length > 0)
            field.passwordCharacter = maskCharacter
    }

    onVisibleChanged: {
        maybeClaim()
        if (visible && enabled)
            focusField()
    }
    onEnabledChanged: {
        maybeClaim()
        if (visible && enabled)
            focusField()
    }

    // Focus recovery: a fresh PAM prompt, a failed attempt, or a watchdog
    // abort all clear inProgress; re-arm only when actually usable.
    Connections {
        target: root.context.auth
        function onInProgressChanged() {
            if (!root.context.auth.inProgress && root.visible && root.enabled)
                root.focusField()
        }
    }

    // The deterministic focus moment: the compositor's keyboard-focus
    // grant to the surface, seen as the window's activation. Qt's own
    // activation-time focus resolution runs during that event and would
    // override a direct forceActiveFocus, so defer by one event-loop turn
    // (callLater — a resequencing, not a wall-clock timer).
    property bool windowActive: Window.active
    onWindowActiveChanged: { if (windowActive) Qt.callLater(root.focusField) }

    TextInput {
        id: field
        anchors.fill: parent
        verticalAlignment: TextInput.AlignVCenter
        color: root.textColor
        selectionColor: root.selectionColor
        selectedTextColor: root.selectedTextColor
        font.pixelSize: root.fontPixelSize
        echoMode: root.context.auth.responseVisible ? TextInput.Normal : TextInput.Password
        passwordMaskDelay: 0
        enabled: !root.context.auth.inProgress
        maximumLength: root.context.auth.maxResponseSize > 0 ? root.context.auth.maxResponseSize - 1 : 32767
        // Declarative focus from construction: forceActiveFocus alone
        // races the compositor's keyboard-focus grant to the surface and
        // drops first keys (d40 flake).
        focus: true

        // Custom caret only when the theme supplies one (draw-only; the
        // native editor positions it). Omitted: the native caret stays.
        Binding {
            target: field
            property: "cursorDelegate"
            value: root.cursorDelegate
            when: root.cursorDelegate !== null
        }

        // Committed native edits (typing, paste, cut, undo, IME commit):
        // publish coherently; an edit collapses the selection at the caret.
        onTextEdited: {
            if (!root._active || root._syncing)
                return
            var model = root.context.auth.input
            root._publishing = true
            var accepted = model.applyEdit(root._token, root._appliedRevision,
                                           field.text, field.cursorPosition, field.cursorPosition)
            root._publishing = false
            if (accepted)
                root._appliedRevision = model.revision
            else
                root.pull()
        }

        // Selection-only moves: native bounds are stale inside per-edit
        // signals and settle by the next event turn — coalesce.
        onCursorPositionChanged: root.scheduleSelectionFlush()
        onSelectedTextChanged: root.scheduleSelectionFlush()

        onPreeditTextChanged: {
            if (root._active && preeditText.length > 0)
                root.context.auth.input.noteInteraction(root._token)
        }
        onInputMethodComposingChanged: {
            if (root._active)
                root.context.auth.input.setActivity(root._token, field.inputMethodComposing, root._gestureActive)
            if (!field.inputMethodComposing)
                root.attemptRelease()
        }

        TapHandler {
            onPressedChanged: {
                root._gestureActive = pressed
                if (root._active) {
                    root.context.auth.input.setActivity(root._token, field.inputMethodComposing, pressed)
                    if (pressed)
                        root.context.auth.input.noteInteraction(root._token)
                    else
                        root.attemptRelease()
                }
            }
        }

        Keys.onPressed: function (event) {
            if (root._active)
                root.context.auth.input.noteInteraction(root._token)
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                // Both Return/Enter and any themed submit button share the
                // one submission path. While composing, leave the key to
                // the native composition path.
                if (!field.inputMethodComposing) {
                    root.submit()
                    event.accepted = true
                }
            } else if (event.key === Qt.Key_Space && event.modifiers === Qt.NoModifier) {
                // Unmodified Space presses run through the context-owned
                // initial-space tuning; text is never trimmed or rewritten.
                if (root._active
                        && root.context.auth.input.filterInitialSpace(root._token, event.isAutoRepeat))
                    event.accepted = true
            }
        }
        Keys.onReleased: function (event) {
            if (event.key === Qt.Key_Space && root._active)
                root.context.auth.input.noteInitialSpaceRelease(root._token)
        }
    }
}
