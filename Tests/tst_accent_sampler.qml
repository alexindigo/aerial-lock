import QtQuick
import QtTest
import "../Modules/Lock" as LockModule

Item {
    id: root
    width: 100
    height: 100

    Component {
        id: playerComponent
        QtObject {
            property bool hasVideo: true
            property int commands: 0
            function commandAsync(args) {
                // Deliberately never write the screenshot file.
                commands++
            }
        }
    }

    Component {
        id: samplerComponent
        LockModule.AccentSampler { width: 64; height: 40 }
    }

    TestCase {
        name: "AccentSamplerTrackLifecycle"
        when: windowShown

        property var player: null
        property var sampler: null
        property var sensing: null
        property var canvas: null

        function init() {
            player = createTemporaryObject(playerComponent, root)
            sampler = createTemporaryObject(samplerComponent, root, { "player": player })
            for (var i = 0; i < sampler.resources.length; i++) {
                var resource = sampler.resources[i]
                if (resource.shotUrl !== undefined)
                    sensing = resource
            }
            for (var j = 0; j < sampler.children.length; j++) {
                var child = sampler.children[j]
                if (child.loadImage !== undefined)
                    canvas = child
            }
            verify(sensing !== null)
            verify(canvas !== null)
            sampler.trackKey = "old-track"
        }

        function test_track_change_cancels_pending_write_and_retry() {
            sampler.tryShot()
            compare(player.commands, 1)
            verify(sensing.shotUrl.length > 0)
            compare(sensing.attempt, 1)
            sampler.trackKey = "new-track"
            // Beyond the old write (450 ms) + poll (300 ms), but before
            // the new track's 1500 ms settling period permits a new shot.
            wait(1000)
            compare(player.commands, 1, "old write/poll must not retry on the new track")
            compare(sensing.shotUrl, "", "old frame must no longer be loadable")
            compare(sensing.attempt, 0, "the new track starts with a fresh attempt budget")
            compare(sampler.accent, Qt.rgba(0, 0, 0, 0))
        }

        function test_track_change_cannot_repaint_cached_old_frame() {
            sampler.tryShot()
            // Preload an actual saturated frame without writing any shot
            // file. A visibility repaint must not reuse this cached URL.
            var frame = Qt.resolvedUrl("fixtures/accent-frame.svg").toString()
            canvas.loadImage(frame)
            tryVerify(function () { return canvas.isImageLoaded(frame) }, 1000)
            sensing.shotUrl = frame
            sampler.trackKey = ""
            player.hasVideo = false
            player.hasVideo = true
            canvas.requestPaint()
            wait(1000)
            compare(sampler.accent, Qt.rgba(0, 0, 0, 0), "old frame must not tint the new track")
            compare(sensing.shotUrl, "")
            compare(sensing.attempt, 0)
        }

        function cacheFrame() {
            var frame = Qt.resolvedUrl("fixtures/accent-frame.svg").toString()
            canvas.loadImage(frame)
            tryVerify(function () { return canvas.isImageLoaded(frame) }, 1000)
            return frame
        }

        function test_late_video_starts_once_after_settling() {
            player.hasVideo = false
            var frame = cacheFrame()
            wait(1700)
            compare(player.commands, 0, "the first settle has no decoded video")
            compare(sensing.attempt, 0)
            player.hasVideo = true
            wait(1000)
            compare(player.commands, 0, "newly available video must still settle")
            tryCompare(player, "commands", 1, 1000)
            compare(sensing.attempt, 1)
            // Supply the frame from the cache instead of a real screenshot
            // file so the ordinary load/poll/paint path can complete.
            sensing.shotUrl = frame
            wait(1000)
            compare(player.commands, 1, "one sensing pass after late availability")
            verify(sampler.accent.a > 0)
            player.hasVideo = false
            player.hasVideo = true
            wait(1700)
            compare(player.commands, 1, "a sensed track must not be sampled again")
        }

        function test_availability_does_not_restart_pending_settle() {
            wait(1000)
            player.hasVideo = false
            player.hasVideo = true
            // The original settle has only 500 ms left. Restarting it on
            // availability would postpone the shot another full 1500 ms.
            tryCompare(player, "commands", 1, 1000)
            compare(sensing.attempt, 1)
        }

        function test_availability_does_not_restart_inflight_attempt() {
            var frame = cacheFrame()
            tryCompare(player, "commands", 1, 2200)
            sensing.shotUrl = frame
            var oldUrl = sensing.shotUrl
            player.hasVideo = false
            player.hasVideo = true
            compare(sensing.attempt, 1)
            compare(sensing.shotUrl, oldUrl)
            // The existing write/poll must finish on its original schedule.
            wait(1000)
            compare(player.commands, 1)
            compare(sensing.attempt, 1)
            compare(sensing.shotUrl, oldUrl)
            verify(sampler.accent.a > 0)
            wait(1700)
            compare(player.commands, 1, "availability must not queue another settle")
        }

        function test_availability_does_not_restart_exhausted_track() {
            // With no files written, the normal pipeline exhausts its three
            // attempts; wait until the final write and poll have finished.
            tryCompare(player, "commands", 3, 4500)
            wait(1000)
            compare(sensing.attempt, 3)
            player.hasVideo = false
            player.hasVideo = true
            wait(1700)
            compare(player.commands, 3)
            compare(sensing.attempt, 3)
        }
    }
}
