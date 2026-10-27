import QtQuick

// AuthInputState (d43) — the one authoritative record of the editable
// authentication response: draft text, caret and selection anchor, plus the
// initial-space tuning profile and its progress. Homed at
// `LockContext.auth.input`; LockContext stays data/callbacks-only.
//
// Synchronization contract (grounded in the d43 checkpoint-1 native
// characterization, logs/d43-shared-auth-input/checkpoint1-findings.md):
//   - The ACTIVE writer (one AuthField core) publishes coherent
//     {text, cursor, anchor} records via applyEdit/setSelection, guarded by
//     its writer token and the base revision it last applied.
//   - Controller operations (consume/clear) and writer handoff bump
//     `revision`; editors re-pull only when their applied revision lags.
//   - A hidden candidate is registered but never active: it cannot publish,
//     and the model never initializes itself from an editor.
//   - `generation` bumps on every authority change so stale publications
//     from a replaced editor are rejected.
//
// Property mutation discipline: QML has no enforced readonly for imperative
// writes, and a bound readonly facade over an imperative backing breaks
// when a change handler writes the next state (write-during-notify trips
// the binding-loop guard and the facade goes stale — d43 test evidence).
// So state lives in plain properties that are MUTATED ONLY through the
// functions below; the writer token + base-revision guards protect the
// draft. Observers that need a coherent {text, cursor, anchor} snapshot
// must key on `revision` (bumped last in every publish), never on the
// individual properties.
//
// The draft is plaintext in process memory while editing. It never enters
// logs, diagnostics, IPC, config or serialization; tests use synthetic
// strings only. Clearing removes logical references — no secure memory
// zeroization is promised here or anywhere in QML.
QtObject {
    id: root

    // ---- Initial-space tuning constants ----
    // Policies.
    readonly property int policyPreserve: 0       // no suppression
    readonly property int policyIgnoreFirst: 1    // eat an initial Space press
    readonly property int policyIgnoreLeading: 2  // eat leading Spaces until first insertion
    // Scopes (reset boundaries owned here, not by component construction).
    readonly property int scopeLock: 0            // one editing epoch per lock
    readonly property int scopeResponse: 1        // epoch resets per consumed response

    // ---- Authoritative draft (mutated only through the functions below) ----
    property string text: ""
    property int cursorPosition: 0
    property int anchorPosition: 0
    readonly property int selectionStart: Math.min(cursorPosition, anchorPosition)
    readonly property int selectionEnd: Math.max(cursorPosition, anchorPosition)
    property int revision: 0

    // ---- Writer registration / authority (data-only tokens; no Items) ----
    property int activeWriter: -1
    property int generation: 0
    // "" (idle) | "releasing" (outgoing editor flushes when safe) |
    // "awaitingClaim" (incoming editor may claim)
    property string handoffState: ""

    property int _nextToken: 1

    signal handoffCompleted()
    signal handoffAborted()

    // ---- Activity bookkeeping (reported by the active core) ----
    // Handoff readiness reflects live composition/gesture state, NOT a
    // serialized IME session; the native session stays with the editor.
    property bool compositionActive: false
    property bool gestureActive: false
    readonly property bool handoffReady: activeWriter !== -1 && !compositionActive && !gestureActive

    // ---- Initial-space tuning state ----
    property int effectivePolicy: policyPreserve
    property int effectiveScope: scopeLock
    property bool tuningLatched: false
    property bool initialWindowOpen: true
    property bool ignoredPressActive: false

    function _clamp(pos, length) {
        return Math.max(0, Math.min(pos, length))
    }

    // One coherent record write: caret/anchor first, then text, then the
    // revision bump that observers key on. A publish that changes nothing
    // is a no-op (no revision bump, no tuning side effects).
    function _publish(newText, cursor, anchor) {
        var nc = _clamp(cursor, newText.length)
        var na = _clamp(anchor, newText.length)
        if (newText === text && nc === cursorPosition && na === anchorPosition)
            return
        cursorPosition = nc
        anchorPosition = na
        text = newText
        revision++
    }

    // ---- Editor-facing operations (active writer only) ----

    function registerWriter() {
        return _nextToken++
    }

    // Normal activation: the visible, enabled editor claims an idle model.
    function claimWriter(token) {
        if (activeWriter !== -1 || handoffState !== "")
            return false
        activeWriter = token
        generation++
        return true
    }

    // Publish a coherent edit. Edits collapse the selection at the caret
    // (native behavior, checkpoint-1 finding 2). Rejected publications
    // (stale token or base revision) return false; the editor must re-pull.
    function applyEdit(token, baseRevision, newText, cursor, anchor) {
        if (token !== activeWriter || baseRevision !== revision)
            return false
        // Accepted TEXT INSERTION closes the initial-input window (and
        // never reopens it). A content-preserving publish — the flush a
        // core performs at submission or handoff — is not an insertion.
        var contentChanged = newText !== text
        _publish(newText, cursor, anchor)
        if (contentChanged)
            initialWindowOpen = false
        return true
    }

    function setSelection(token, baseRevision, cursor, anchor) {
        if (token !== activeWriter || baseRevision !== revision)
            return false
        cursorPosition = _clamp(cursor, text.length)
        anchorPosition = _clamp(anchor, text.length)
        revision++
        return true
    }

    // The active core offers its tunings before editing begins. Once any
    // interaction latches the epoch, later offers (e.g. a promoted theme)
    // cannot change the effective profile.
    function offerTunings(token, policy, scope) {
        if (token !== activeWriter || tuningLatched)
            return
        effectivePolicy = policy
        effectiveScope = scope
    }

    // Any delivered interaction latches the tuning profile for the epoch —
    // even an ignored Space.
    function noteInteraction(token) {
        if (token === activeWriter)
            tuningLatched = true
    }

    // Called by the active core for an unmodified Space key PRESS.
    // Returns true when the event must be consumed (never reaches the
    // TextInput). Text is never trimmed or rewritten here.
    function filterInitialSpace(token, isAutoRepeat) {
        if (token !== activeWriter)
            return false
        if (effectivePolicy === policyPreserve)
            return false
        if (effectivePolicy === policyIgnoreFirst) {
            if (isAutoRepeat)
                return ignoredPressActive
            if (initialWindowOpen) {
                initialWindowOpen = false
                ignoredPressActive = true
                return true
            }
            return false
        }
        // ignoreLeading: consume while the window is open, press or repeat.
        return initialWindowOpen
    }

    // Called by the active core on Space key release.
    function noteInitialSpaceRelease(token) {
        if (token === activeWriter)
            ignoredPressActive = false
    }

    function setActivity(token, composing, gesture) {
        if (token !== activeWriter)
            return
        compositionActive = composing
        gestureActive = gesture
    }

    // ---- Handoff lifecycle ----

    // The host requests elective replacement (candidate prepared).
    function requestHandoff() {
        if (handoffState !== "")
            return
        handoffState = activeWriter === -1 ? "awaitingClaim" : "releasing"
    }

    // The active core releases after its final synchronous flush, only when
    // no native composition or edit gesture is live.
    function releaseWriter(token) {
        if (token !== activeWriter)
            return false
        activeWriter = -1
        compositionActive = false
        gestureActive = false
        generation++
        if (handoffState === "releasing")
            handoffState = "awaitingClaim"
        return true
    }

    // The incoming editor claims during a handoff (before it is visible).
    function claimHandoff(token) {
        if (handoffState !== "awaitingClaim")
            return false
        activeWriter = token
        handoffState = ""
        generation++
        handoffCompleted()
        return true
    }

    // The host aborts (candidate failed after the request): a released
    // outgoing editor re-claims on handoffAborted; an unreleased one simply
    // stops deferring because handoffState returns to "".
    function abortHandoff() {
        if (handoffState === "")
            return
        handoffState = ""
        handoffAborted()
    }

    // ---- Controller operations (Lock.qml; never widget-lifetime-driven) ----

    // Accepted submission: snapshot the draft once and clear every mirror.
    // Response-scoped tunings begin a new epoch: the next empty editable
    // response reopens the initial-input window and re-arms offers.
    function consume() {
        var draft = text
        _publish("", 0, 0)
        if (effectiveScope === scopeResponse) {
            initialWindowOpen = true
            ignoredPressActive = false
            tuningLatched = false
        }
        return draft
    }

    // Explicit clear (documented draft-discard path; not a response
    // boundary: tuning progress is preserved).
    function clear() {
        _publish("", 0, 0)
    }
}
