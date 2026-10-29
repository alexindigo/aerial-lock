import QtQuick
import QtTest
import "../Modules/Lock" as LockModule

// Run only through CTest `media-fallback`, which preloads the test-only
// libfull-caller-faults.so with AERIAL_TEST_FULL_CALLER_FAULT=core-create
// (deliberately not named tst_*: it needs that injected native failure).
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
    }
}
