import QtQuick
import "../Services" as Services
import "../Modules/Lock" as LockModule

// d43 native-input probe fixture (test-only). One fresh "rig" per phase:
// a real LockContext, the shared AuthField core as the visible editor, a
// second (initially hidden) core for handoff, and a fake controller that
// mimics Lock.qml's zero-argument acceptance. Synthetic strings only; the
// C++ probe drives real key events, clipboard and public QInputMethodEvent
// injection, and inspects both the model and the native editor.
Item {
    id: root
    width: 640
    height: 480

    property var rig: null
    property string outState: ""

    Component {
        id: rigComponent
        Item {
            id: rigRoot
            property int policy: 0
            property int scope: 0
            property var context: ctx
            property alias fieldA: fieldA
            property alias fieldB: fieldB
            property int submitCount: 0
            property var accepted: []
            property bool rigReady: false

            Services.LockContext { id: ctx }

            Connections {
                target: ctx
                function onSubmitRequested() {
                    if (ctx.auth.inProgress)
                        return
                    rigRoot.accepted.push(ctx.auth.input.consume())
                    rigRoot.submitCount++
                }
            }

            LockModule.AuthField {
                id: fieldA
                context: ctx
                width: 200
                height: 40
                // Claims (and offers tunings) only when shown — see
                // rigRoot.Component.onCompleted. Child completion order is
                // unreliable, so the claim must not happen at construction.
                visible: false
            }
            LockModule.AuthField {
                id: fieldB
                context: ctx
                width: 200
                height: 40
                y: 60
                visible: false
            }

            Component.onCompleted: {
                // Creation properties are applied before this runs. Assign
                // the phase tunings, THEN show fieldA: its claim offers the
                // final values, while the epoch is unlatched.
                fieldA.initialSpacePolicy = rigRoot.policy
                fieldA.initialSpaceScope = rigRoot.scope
                fieldB.initialSpacePolicy = rigRoot.policy
                fieldB.initialSpaceScope = rigRoot.scope
                fieldA.visible = true
                fieldA.focusField()
                rigRoot.rigReady = true
            }
        }
    }

    function newRig(policy, scope) {
        if (rig) {
            rig.destroy()
            rig = null
        }
        rig = rigComponent.createObject(root, { "policy": policy, "scope": scope })
        return rig
    }

    // d44: apply every presentation seam to fieldA after creation (the
    // core applies them on change; no draft/writer/tuning impact allowed).
    Component {
        id: caretComponent
        Rectangle {
            width: 2
            height: 18
            color: "#ff00ff"
        }
    }

    function styleFieldA() {
        rig.fieldA.fontFamily = "DejaVu Sans"
        rig.fieldA.fontWeight = Font.Bold
        rig.fieldA.fontLetterSpacing = 2
        rig.fieldA.horizontalAlignment = TextInput.AlignHCenter
        rig.fieldA.maskCharacter = "✦"
        rig.fieldA.cursorDelegate = caretComponent
    }

    function setBusy(busy) { rig.context.auth.inProgress = busy }
    function setMaxResp(n) { rig.context.auth.maxResponseSize = n }
    function requestHandoff() { rig.context.auth.input.requestHandoff() }
    function promoteB() {
        rig.fieldB.visible = true
        rig.fieldB.focusField()
    }

    function snap() {
        if (!rig) {
            outState = "{}"
            return
        }
        var m = rig.context.auth.input
        outState = JSON.stringify({
            text: m.text,
            cursor: m.cursorPosition,
            anchor: m.anchorPosition,
            rev: m.revision,
            active: m.activeWriter,
            state: m.handoffState,
            windowOpen: m.initialWindowOpen,
            latched: m.tuningLatched,
            effPolicy: m.effectivePolicy,
            rigPolicy: rig.policy,
            rigReady: rig.rigReady,
            submits: rig.submitCount,
            accepted: rig.accepted,
            aToken: rig.fieldA._token,
            bToken: rig.fieldB._token,
            aPolicy: rig.fieldA.initialSpacePolicy,
            aFocus: rig.fieldA.hasActiveFocus,
            bFocus: rig.fieldB.hasActiveFocus
        })
    }
}
