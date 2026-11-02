import QtQuick
import QtTest
import "../Services" as Services

Item {
    id: root
    Component { id: reportComponent; Services.EngagementReport { path: ""; secure: false } }
    Component { id: spyComponent; SignalSpy {} }
    TestCase {
        name: "EngagementCommands"
        when: windowShown
        function test_exact_release_only_data() {
            return [
                { tag: "release", line: "release", releases: 1 },
                { tag: "space", line: " release", releases: 0 },
                { tag: "suffix", line: "release ", releases: 0 },
                { tag: "case", line: "Release", releases: 0 },
                { tag: "empty", line: "", releases: 0 },
                { tag: "carriage-return", line: "release\r", releases: 0 }
            ]
        }
        function test_exact_release_only(data) {
            failOnWarning(/.*/)
            var report = createTemporaryObject(reportComponent, root)
            var spy = createTemporaryObject(spyComponent, root, { target: report, signalName: "releaseRequested" })
            var parser = findChild(report, "engagementReportParser")
            verify(parser !== null)
            if (!data.releases)
                ignoreWarning(/EngagementReport: ignored an unknown supervisor command/)
            parser.read(data.line)
            compare(spy.count, data.releases)
        }
        function test_unknown_warns_once_then_release_still_delivered() {
            failOnWarning(/.*/)
            var report = createTemporaryObject(reportComponent, root)
            var spy = createTemporaryObject(spyComponent, root, { target: report, signalName: "releaseRequested" })
            var parser = findChild(report, "engagementReportParser")
            ignoreWarning(/EngagementReport: ignored an unknown supervisor command/)
            parser.read("unknown")
            parser.read("still unknown")
            compare(spy.count, 0)
            parser.read("release")
            compare(spy.count, 1)
        }
    }
}
