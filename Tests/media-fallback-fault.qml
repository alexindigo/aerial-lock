import QtQuick
import QtTest
import "../Modules/Lock" as LockModule

// Run through CTest: `media-fallback` preloads the test-only
// libfull-caller-faults.so with AERIAL_TEST_FULL_CALLER_FAULT=core-create and
// runs the core case; `media-fallback-render` runs the render case, which needs
// a Qt platform that actually renders video (it skips on offscreen). Not named
// tst_*: each case needs its own environment.
TestCase {
    id: tests
    name: "MediaFallbackFault"
    when: windowShown
    width: 64
    height: 40

    Component {
        id: backgroundComponent
        LockModule.LockBackground { width: 64; height: 40 }
    }

    function player(background) {
        for (var i = 0; i < background.children.length; i++) {
            if (background.children[i].coreAvailable !== undefined)
                return background.children[i]
        }
        return null
    }

    function test_core_failure_keeps_solid_scenery_and_reports_once() {
        var background = createTemporaryObject(backgroundComponent, tests.parent)
        var failures = []
        background.loadFailed.connect(function (message) { failures.push(message) })
        var mpv = player(background)
        verify(mpv !== null)
        background.items = [{ kind: "file", path: "/nonexistent/clip.mp4" }]
        tryVerify(function () { return background.mediaFailed }, 5000, "native failure retires the scenery")
        verify(!mpv.visible, "solid surface colour, no player")
        verify(!background.hasVideo)
        compare(background.accentColor, Qt.rgba(0, 0, 0, 0))
        wait(200)
        var created = failures.filter(function (m) { return m.indexOf("core creation failed") >= 0 })
        compare(created.length, 1, "one native failure is reported once")
        var before = failures.length
        background.items = [{ kind: "file", path: "/nonexistent/other.mp4" }]
        wait(300)
        compare(failures.length, before, "a failed background loads nothing more")
        background.shutdown()
        background.shutdown() // idempotent
        compare(failures.length, before, "no stop is attempted without a core")
    }

    // mpvqml keeps the core and playback intent across a render failure; the
    // hidden background must stop instead of decoding behind the solid colour,
    // and a later renderer recovery must not resume it.
    function test_render_failure_stops_hidden_playback() {
        var background = createTemporaryObject(backgroundComponent, tests.parent)
        var failures = []
        background.loadFailed.connect(function (message) { failures.push(message) })
        var mpv = player(background)
        verify(mpv !== null)
        background.items = [{ kind: "file", path: "av://lavfi:testsrc2=size=320x240:rate=25" }]
        var deadline = Date.now() + 10000
        while (!(mpv.hasVideo && mpv.position > 0.3) && Date.now() < deadline)
            wait(50)
        if (!mpv.hasVideo)
            skip("needs a Qt platform that renders video")
        verify(mpv.coreAvailable)
        mpv.renderingFailed(-1, "injected render loss") // as the player emits it
        verify(background.mediaFailed)
        verify(!mpv.visible, "solid surface colour")
        tryVerify(function () { return mpv.paused }, 2000, "playback paused")
        tryVerify(function () { return mpv.playlist.length === 0 }, 3000, "playback stopped")
        var position = mpv.position
        wait(1000)
        verify(Math.abs(mpv.position - position) < 0.05, "no hidden decoding")
        mpv.ready() // a later successful renderer generation
        wait(1000)
        compare(mpv.playlist.length, 0, "recovery does not restart playback")
        verify(Math.abs(mpv.position - position) < 0.05, "recovery does not resume decoding")
        background.shutdown()
        compare(failures.length, 0, "stopping reports nothing")
    }
}
