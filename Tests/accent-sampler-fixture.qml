import QtQuick
import QtCore
import "../Modules/Lock" as LockModule

Item {
    id: fixture
    width: 256
    height: 128
    property alias sampler: sampler
    property alias fakePlayer: fakePlayer
    property alias imageWriter: writer
    property int writerPaints: 0
    property bool lastSaveSucceeded: false
    property color paintColor: "#80c040"
    // The sampler's private directory; the runner's TMPDIR here (QML cannot
    // create directories). Run the suites with a disposable TMPDIR.
    readonly property string frameDirectory: StandardPaths.writableLocation(StandardPaths.TempLocation)
            .toString().replace(/^file:\/\//, "")

    QtObject {
        id: fakePlayer
        property bool hasVideo: true
        property int nextId: 1
        property int reject: 0
        property int submissions: 0
        property var calls: []
        signal asyncCommandFinished(int id, int error, var result)
        function commandAsync(params) {
            submissions++
            if (reject < 0)
                return reject
            var id = nextId++
            // The sampler keys its n-th shot's image as <file>?shot=<n>.
            calls = calls.concat([{ id: id, path: params[1],
                                    url: "file://" + params[1] + "?shot=" + submissions }])
            return id
        }
        function finish(id, error, writeImage) {
            var call = calls.filter(function (entry) { return entry.id === id })[0]
            if (call && error === 0 && writeImage)
                fixture.lastSaveSucceeded = writer.save(call.path)
            Qt.callLater(function () { fakePlayer.asyncCommandFinished(id, error, null) })
        }
    }

    Canvas {
        id: writer
        x: 100
        // save(imageSize) captures that region, rather than scaling the small
        // paint. Draw a genuine 4K source; the sampler decodes it at 64x40.
        width: 3840
        height: 2160
        renderTarget: Canvas.Image
        renderStrategy: Canvas.Immediate
        onPaint: {
            var context = getContext("2d")
            context.fillStyle = fixture.paintColor
            context.fillRect(0, 0, width, height)
            fixture.writerPaints++
        }
    }
    LockModule.AccentSampler {
        id: sampler
        width: 64
        height: 40
        player: fakePlayer
        trackKey: "A"
        shotDirectory: fixture.frameDirectory
        active: true
    }
}
