import QtQuick
import QtTest

TestCase {
    id: tests
    name: "AccentSamplerTransactions"
    when: windowShown
    width: 256
    height: 128
    property var fixture: null
    // A lower-case file is created explicitly to retain the planned fixture name.
    function init() {
        var component = Qt.createComponent("accent-sampler-fixture.qml")
        compare(component.status, Component.Ready, component.errorString())
        // TestCase itself is not a painted surface; both Canvases must remain
        // in the visible runner scene, as the production sampler does.
        fixture = component.createObject(tests.parent)
        verify(fixture !== null)
        tryCompare(fixture.imageWriter, "available", true, 2000)
        fixture.imageWriter.requestPaint()
        wait(50)
        verify(fixture.writerPaints > 0)
    }
    function cleanup() {
        if (fixture) {
            fixture.sampler.shutdown()
            fixture.destroy()
        }
        fixture = null
        wait(0)
    }
    function firstCall() {
        tryVerify(function () { return fixture.fakePlayer.calls.length === 1 }, 2500)
        return fixture.fakePlayer.calls[0]
    }
    function test_completion_drives_real_image_paint_and_unload() {
        var call = firstCall()
        fixture.fakePlayer.asyncCommandFinished(call.id + 100, 0, null)
        wait(50)
        compare(fixture.fakePlayer.calls.length, 1)
        compare(fixture.sampler.accent.a, 0)
        fixture.fakePlayer.finish(call.id, 0, true)
        verify(fixture.lastSaveSucceeded)
        tryVerify(function () { return fixture.sampler.accent.a > 0.9 }, 2500)
        verify(fixture.sampler.accent.g > fixture.sampler.accent.r)
        verify(fixture.sampler.accent.r > fixture.sampler.accent.b)
        var canvas = findChild(fixture.sampler, "accentCanvas")
        verify(canvas !== null)
        verify(!canvas.isImageLoaded(call.url))
        verify(!canvas.isImageLoading(call.url))
        canvas.requestPaint() // incidental paints must not implicitly reload it
        wait(50)
        verify(!canvas.isImageLoaded(call.url))
        compare(fixture.fakePlayer.calls.length, 1)
    }
    function test_supersession_keeps_one_command_and_C_own_settle() {
        var old = firstCall()
        fixture.sampler.trackKey = "B"
        wait(100)
        fixture.sampler.trackKey = "C"
        fixture.fakePlayer.finish(old.id, 0, true)
        wait(500)
        compare(fixture.fakePlayer.calls.length, 1)
        compare(fixture.sampler.accent.a, 0) // old green reply cannot tint C
        fixture.paintColor = "#4080c0"
        var paints = fixture.writerPaints
        fixture.imageWriter.requestPaint()
        tryVerify(function () { return fixture.writerPaints > paints }, 1000)
        tryVerify(function () { return fixture.fakePlayer.calls.length === 2 }, 2000)
        var current = fixture.fakePlayer.calls[1]
        fixture.fakePlayer.finish(current.id, 0, true)
        tryVerify(function () { return fixture.sampler.accent.a > 0.9 }, 2500)
        verify(fixture.sampler.accent.b > fixture.sampler.accent.g)
        verify(fixture.sampler.accent.g > fixture.sampler.accent.r)
        var canvas = findChild(fixture.sampler, "accentCanvas")
        verify(!canvas.isImageLoaded(old.url))
        verify(!canvas.isImageLoaded(current.url))
    }
    function test_delayed_native_rejection_retries_at_most_three() {
        var call = firstCall()
        fixture.fakePlayer.finish(call.id, -12, false)
        tryVerify(function () { return fixture.fakePlayer.calls.length === 2 }, 1500)
        fixture.fakePlayer.finish(fixture.fakePlayer.calls[1].id, -12, false)
        tryVerify(function () { return fixture.fakePlayer.calls.length === 3 }, 1500)
        fixture.fakePlayer.finish(fixture.fakePlayer.calls[2].id, -12, false)
        wait(700)
        compare(fixture.fakePlayer.calls.length, 3)
        compare(fixture.sampler.accent.a, 0)
    }
    function test_shutdown_before_late_success_never_loads_or_retries() {
        var call = firstCall()
        fixture.sampler.shutdown()
        fixture.fakePlayer.finish(call.id, 0, true)
        wait(700)
        compare(fixture.fakePlayer.calls.length, 1)
        compare(fixture.sampler.accent.a, 0)
        var canvas = findChild(fixture.sampler, "accentCanvas")
        verify(!canvas.isImageLoaded(call.url))
        verify(!canvas.isImageLoading(call.url))
    }
    function test_command_deadline_does_not_free_slot() {
        var call = firstCall()
        wait(5200)
        compare(fixture.fakePlayer.calls.length, 1)
        fixture.sampler.trackKey = "new"
        wait(1600)
        compare(fixture.fakePlayer.calls.length, 1)
        fixture.fakePlayer.finish(call.id, 0, true)
        tryVerify(function () { return fixture.fakePlayer.calls.length === 2 }, 1500)
    }
    function test_immediate_admission_rejection_has_no_pending_completion() {
        fixture.fakePlayer.reject = -12
        tryCompare(fixture.fakePlayer, "submissions", 3, 3000)
        wait(700)
        compare(fixture.fakePlayer.submissions, 3)
        compare(fixture.fakePlayer.calls.length, 0)
        fixture.fakePlayer.reject = 0
        fixture.sampler.trackKey = "admitted-after-rejection"
        var call = firstCall()
        fixture.fakePlayer.finish(call.id, 0, true)
        tryVerify(function () { return fixture.sampler.accent.a > 0.9 }, 2500)
    }
    function test_success_without_an_image_retries_and_unloads_errors() {
        var canvas = findChild(fixture.sampler, "accentCanvas")
        var call = firstCall()
        fixture.fakePlayer.finish(call.id, 0, false)
        tryVerify(function () { return fixture.fakePlayer.calls.length === 2 }, 2000)
        verify(!canvas.isImageLoaded(call.url))
        verify(!canvas.isImageLoading(call.url))
        var retry = fixture.fakePlayer.calls[1]
        fixture.fakePlayer.finish(retry.id, 0, true)
        tryVerify(function () { return fixture.sampler.accent.a > 0.9 }, 2500)
        verify(!canvas.isImageLoaded(retry.url))
    }
    function test_seedless_real_paint_unloads_without_retries() {
        fixture.paintColor = "black"
        var paints = fixture.writerPaints
        fixture.imageWriter.requestPaint()
        tryVerify(function () { return fixture.writerPaints > paints }, 1000)
        var call = firstCall()
        fixture.fakePlayer.finish(call.id, 0, true)
        wait(1000)
        compare(fixture.sampler.accent.a, 0)
        compare(fixture.fakePlayer.calls.length, 1)
        var canvas = findChild(fixture.sampler, "accentCanvas")
        verify(!canvas.isImageLoaded(call.url))
        verify(!canvas.isImageLoading(call.url))
    }
    function test_actual_decoded_source_is_bounded_before_paint() {
        var canvas = findChild(fixture.sampler, "accentCanvas")
        var call = firstCall()
        var dimensions = null
        var inspect = function () {
            if (!canvas.isImageLoaded(call.url)) return
            // Documented Context2D URL overload reads the already-loaded image,
            // not the 64x40 destination or another Image/sourceSize component.
            var source = canvas.getContext("2d").createImageData(call.url)
            dimensions = [source.width, source.height]
        }
        canvas.imageLoaded.connect(inspect)
        fixture.fakePlayer.finish(call.id, 0, true)
        tryVerify(function () { return dimensions !== null }, 2000)
        canvas.imageLoaded.disconnect(inspect)
        verify(dimensions[0] > 0 && dimensions[0] <= 64)
        verify(dimensions[1] > 0 && dimensions[1] <= 40)
        compare(dimensions[0], 64)
        compare(dimensions[1], 36) // 3840x2160 aspect ratio retained during decode
        tryVerify(function () { return fixture.sampler.accent.a > 0.9 }, 2500)
        verify(!canvas.isImageLoaded(call.url))
    }
    function test_image_deadline_unloads_when_paint_cannot_run() {
        var call = firstCall()
        var canvas = findChild(fixture.sampler, "accentCanvas")
        var loaded = false
        var inspect = function () { loaded = loaded || canvas.isImageLoaded(call.url) }
        canvas.imageLoaded.connect(inspect)
        // Remove only visual attachment; QObject ownership remains with the
        // sampler. A loaded image cannot reach a window's polish/paint pass.
        canvas.parent = null
        fixture.fakePlayer.finish(call.id, 0, true)
        tryVerify(function () { return loaded }, 1500)
        tryVerify(function () { return fixture.fakePlayer.calls.length === 2 }, 3000)
        canvas.imageLoaded.disconnect(inspect)
        compare(fixture.sampler.accent.a, 0)
        verify(!canvas.isImageLoaded(call.url))
        verify(!canvas.isImageLoading(call.url))
    }
    function test_paint_exception_unloads_captured_url_then_recovers() {
        var call = firstCall()
        var canvas = findChild(fixture.sampler, "accentCanvas")
        var context = canvas.getContext("2d")
        var original = context.getImageData
        var entered = 0
        var trap = function () { entered++; throw new Error("test-only pixel extraction failure") }
        context.getImageData = trap
        compare(context.getImageData, trap)
        try {
            fixture.fakePlayer.finish(call.id, 0, true)
            tryVerify(function () { return fixture.fakePlayer.calls.length === 2 }, 2000)
            verify(entered > 0)
            verify(!canvas.isImageLoaded(call.url))
            verify(!canvas.isImageLoading(call.url))
        } finally {
            context.getImageData = original
        }
        fixture.fakePlayer.finish(fixture.fakePlayer.calls[1].id, 0, true)
        tryVerify(function () { return fixture.sampler.accent.a > 0.9 }, 2500)
    }
    Component {
        id: replacementFactory
        QtObject {
            property bool hasVideo: true
            property var calls: []
            signal asyncCommandFinished(int id, int error, var result)
            function commandAsync(params) {
                var id = calls.length + 1
                calls = calls.concat([{ id: id, path: params[1], url: "file://" + params[1] }])
                return id
            }
        }
    }
    function test_live_player_replacement_keeps_old_pending_slot() {
        var old = firstCall()
        var replacement = replacementFactory.createObject(tests.parent)
        fixture.sampler.player = replacement
        wait(1700)
        compare(replacement.calls.length, 0)
        fixture.fakePlayer.finish(old.id, 0, true)
        tryVerify(function () { return replacement.calls.length === 1 }, 1500)
        replacement.asyncCommandFinished(replacement.calls[0].id, -12, null)
        fixture.sampler.shutdown()
        replacement.destroy()
    }
    function test_retired_player_releases_pending_receiver_slot() {
        var old = firstCall()
        fixture.fakePlayer.finish(old.id, -12, false)
        wait(0)
        fixture.sampler.shutdown()
        // A fresh sampler owner below is deliberate: the first player has no
        // outstanding operation, rather than concealing an unresolved command.
        fixture.destroy()
        var component = Qt.createComponent("accent-sampler-fixture.qml")
        fixture = component.createObject(tests.parent)
        var retiring = replacementFactory.createObject(tests.parent)
        fixture.sampler.player = retiring
        tryVerify(function () { return retiring.calls.length === 1 }, 2500)
        fixture.sampler.player = fixture.fakePlayer
        wait(1700)
        compare(fixture.fakePlayer.calls.length, 0)
        retiring.destroy()
        tryVerify(function () { return fixture.fakePlayer.calls.length === 1 }, 1500)
    }
    function test_owner_deletion_with_outstanding_completion() {
        var call = firstCall()
        var player = replacementFactory.createObject(tests.parent)
        fixture.sampler.player = player
        fixture.fakePlayer.finish(call.id, -12, false)
        tryVerify(function () { return player.calls.length === 1 }, 2500)
        var id = player.calls[0].id
        fixture.destroy()
        fixture = null
        wait(0)
        player.asyncCommandFinished(id, 0, null)
        wait(700)
        compare(player.calls.length, 1)
        player.destroy()
    }
    // Track/availability contract carried over from the per-track suite:
    // the old shot pipeline never serves a new track, late video still
    // settles, and availability never re-samples or restarts a transaction.
    function test_track_change_cancels_old_retry() {
        var old = firstCall()
        fixture.sampler.trackKey = "new-track"
        fixture.fakePlayer.finish(old.id, -12, false)
        // Beyond the old retry backoff, before the new track's settle ends.
        wait(1000)
        compare(fixture.fakePlayer.calls.length, 1, "old retry must not run on the new track")
        compare(fixture.sampler.accent.a, 0)
        tryVerify(function () { return fixture.fakePlayer.calls.length === 2 }, 1500)
        fixture.fakePlayer.finish(fixture.fakePlayer.calls[1].id, 0, true)
        tryVerify(function () { return fixture.sampler.accent.a > 0.9 }, 2500)
    }
    function test_old_frame_cannot_tint_new_track() {
        var old = firstCall()
        var canvas = findChild(fixture.sampler, "accentCanvas")
        fixture.fakePlayer.finish(old.id, 0, true) // completion is delivered later
        fixture.sampler.trackKey = "new-track"
        wait(500)
        compare(fixture.sampler.accent.a, 0, "old frame must not tint the new track")
        verify(!canvas.isImageLoaded(old.url))
        verify(!canvas.isImageLoading(old.url))
    }
    function test_late_video_still_settles_and_is_sensed_once() {
        fixture.fakePlayer.hasVideo = false
        wait(1700)
        compare(fixture.fakePlayer.submissions, 0, "the first settle has no decoded video")
        fixture.fakePlayer.hasVideo = true
        wait(1000)
        compare(fixture.fakePlayer.submissions, 0, "newly available video must still settle")
        var call = firstCall()
        fixture.fakePlayer.finish(call.id, 0, true)
        tryVerify(function () { return fixture.sampler.accent.a > 0.9 }, 2500)
        fixture.fakePlayer.hasVideo = false
        fixture.fakePlayer.hasVideo = true
        wait(1700)
        compare(fixture.fakePlayer.submissions, 1, "a sensed track must not be sampled again")
    }
    function test_availability_does_not_resample_sensed_track() {
        var call = firstCall()
        fixture.fakePlayer.finish(call.id, 0, true)
        tryVerify(function () { return fixture.sampler.accent.a > 0.9 }, 2500)
        fixture.fakePlayer.hasVideo = false
        fixture.fakePlayer.hasVideo = true
        wait(1700)
        compare(fixture.fakePlayer.submissions, 1)
        verify(fixture.sampler.accent.a > 0.9)
    }
    function test_availability_does_not_restart_pending_settle() {
        wait(800)
        fixture.fakePlayer.hasVideo = false
        fixture.fakePlayer.hasVideo = true
        // The original settle has under 700 ms left; a restart would postpone
        // the shot by another full 1500 ms.
        tryVerify(function () { return fixture.fakePlayer.calls.length === 1 }, 1200)
    }
    function test_availability_does_not_restart_inflight_or_exhausted_track() {
        var call = firstCall()
        fixture.fakePlayer.hasVideo = false
        fixture.fakePlayer.hasVideo = true
        wait(1700)
        compare(fixture.fakePlayer.submissions, 1, "in-flight transaction is not restarted")
        fixture.fakePlayer.finish(call.id, -12, false)
        tryVerify(function () { return fixture.fakePlayer.calls.length === 2 }, 1500)
        fixture.fakePlayer.finish(fixture.fakePlayer.calls[1].id, -12, false)
        tryVerify(function () { return fixture.fakePlayer.calls.length === 3 }, 1500)
        fixture.fakePlayer.finish(fixture.fakePlayer.calls[2].id, -12, false)
        wait(700)
        fixture.fakePlayer.hasVideo = false
        fixture.fakePlayer.hasVideo = true
        wait(1700)
        compare(fixture.fakePlayer.submissions, 3, "an exhausted track is not restarted")
        compare(fixture.sampler.accent.a, 0)
    }
}
