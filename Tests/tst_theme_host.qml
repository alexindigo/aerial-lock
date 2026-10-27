import QtQuick
import QtTest
import "../Services" as Services
import "../Modules/Lock" as LockModule

Item {
    id: root
    width: 640
    height: 480

    Component {
        id: contextComponent
        Services.LockContext {}
    }

    Component {
        id: hostComponent
        LockModule.ThemeHost {
            width: 640
            height: 480
            // Keep the fallback editor from claiming our synthetic writer.
            visible: false
            config: null
            logger: Services.Logger
        }
    }

    Component {
        id: spyComponent
        SignalSpy {}
    }

    TestCase {
        name: "ThemeHostClaimGrace"
        when: windowShown

        property var ctx: null
        property var model: null
        property var host: null
        property var candidate: null
        property var fallbackSpy: null
        property var readySpy: null
        property int writer: -1

        function init() {
            ctx = contextComponent.createObject(root)
            model = ctx.auth.input
            writer = model.registerWriter()
            verify(model.claimWriter(writer))
            model.applyEdit(writer, model.revision, "synthetic-draft", 3, 1)
            host = createTemporaryObject(hostComponent, root, { "context": ctx })
            // The synthetic writer stands in for the outgoing fallback.
            // Its real, inactive AuthField must not compete for the claim.
            var fallbackField = findField(host)
            verify(fallbackField !== null)
            fallbackField._releasedForHandoff = true
            fallbackSpy = createTemporaryObject(spyComponent, root,
                { "target": host, "signalName": "fallbackRequested" })
            readySpy = createTemporaryObject(spyComponent, root,
                { "target": host, "signalName": "ready" })
        }

        function cleanup() {
            // Keep the context alive until all consumer bindings are gone.
            host.destroy()
            wait(0)
            ctx.destroy()
            wait(0)
        }

        function findField(item) {
            if (item._releasedForHandoff !== undefined)
                return item
            for (var i = 0; i < item.children.length; i++) {
                var field = findField(item.children[i])
                if (field)
                    return field
            }
            return null
        }

        function loadCandidate() {
            // Isolate the real Loader.onLoaded handoff path from config and
            // filesystem probing (covered by the nested-shell camera gate).
            var lifecycle = null
            var loader = null
            for (var i = 0; i < host.resources.length; i++) {
                var resource = host.resources[i]
                if (resource.handoffPending !== undefined)
                    lifecycle = resource
            }
            for (var j = 0; j < host.children.length; j++) {
                var child = host.children[j]
                if (child.setSource !== undefined)
                    loader = child
            }
            verify(lifecycle !== null)
            verify(loader !== null)
            lifecycle.phase = "candidate"
            host.allowLoading = true
            loader.setSource(Qt.resolvedUrl("fixtures/HandoffTheme.qml"), { "context": ctx })
            tryVerify(function () { return loader.item !== null }, 1000)
            candidate = loader.item
            tryVerify(function () { return model.handoffState !== "" }, 1000)
        }

        function expectClaimFailure() {
            ignoreWarning(/ThemeHost: theme .* failed: theme editor did not claim the shared draft - using built-in panel/)
        }

        function test_long_composition_waits_then_promotes() {
            model.setActivity(writer, true, false)
            loadCandidate()
            compare(model.handoffState, "releasing")
            wait(1700)
            verify(!host.settled, "composition must not consume the claim grace")
            compare(fallbackSpy.count, 0)
            compare(readySpy.count, 0)
            compare(model.activeWriter, writer)
            verify(model.compositionActive)
            model.setActivity(writer, false, false)
            verify(model.releaseWriter(writer))
            compare(model.handoffState, "awaitingClaim")
            verify(candidate.claim())
            verify(host.settled)
            verify(!host.usingFallback)
            compare(model.activeWriter, candidate.writerToken)
            compare(candidate.draft, "synthetic-draft")
            compare(model.cursorPosition, 3)
            compare(model.anchorPosition, 1)
            compare(readySpy.count, 1)
            // Promotion must also stop the grace that was just armed.
            wait(1200)
            compare(fallbackSpy.count, 0)
            verify(!host.usingFallback)
        }

        function test_deferred_release_without_claim_times_out() {
            model.setActivity(writer, true, false)
            loadCandidate()
            wait(1700)
            verify(!host.settled)
            model.setActivity(writer, false, false)
            expectClaimFailure()
            verify(model.releaseWriter(writer))
            compare(model.handoffState, "awaitingClaim")
            wait(500)
            verify(!host.settled, "release starts a fresh grace period")
            tryCompare(host, "settled", true, 1500)
            verify(host.usingFallback)
            compare(fallbackSpy.count, 1)
            compare(readySpy.count, 1)
            compare(model.handoffState, "")
            compare(candidate.draft, "synthetic-draft")
        }

        function test_immediate_awaiting_claim_times_out() {
            verify(model.releaseWriter(writer))
            expectClaimFailure()
            loadCandidate()
            compare(model.handoffState, "awaitingClaim")
            wait(500)
            verify(!host.settled)
            tryCompare(host, "settled", true, 1500)
            verify(host.usingFallback)
            compare(fallbackSpy.count, 1)
        }

        function test_unrelated_handoff_does_not_arm_host_grace() {
            // No candidate has prepared and this host owns no handoff.
            verify(model.releaseWriter(writer))
            model.requestHandoff()
            compare(model.handoffState, "awaitingClaim")
            wait(1300)
            verify(!host.settled)
            compare(fallbackSpy.count, 0)
            model.abortHandoff()
        }
    }
}
