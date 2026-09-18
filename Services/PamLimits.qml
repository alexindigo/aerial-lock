import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    // 0 = unknown. There is no fallback number: the field cap is a
    // convenience (stopping the user typing more than PAM will accept),
    // never a security control, so when the real limit is unknown
    // asserting one would be fabrication.
    property int maxResponseSize: 0
    property string source: ""   // provenance, for logging only

    readonly property string limitsPath: Quickshell.shellDir + "/Config/pam-limits.json"

    FileView {
        id: limitsFile
        path: limitsPath
        blockLoading: true
        printErrors: false
    }

    Component.onCompleted: {
        // waitForJob() returning false means no load was ever queued for the
        // path — a structural defect, not a slow disk. With blockLoading the
        // read below is definitive either way: empty means genuinely missing
        // or unreadable, never "not loaded yet".
        if (!limitsFile.waitForJob()) {
            console.warn("PamLimits: no load job was queued for", limitsPath)
        }
        var raw = limitsFile.text()
        if (raw && raw.length > 0) {
            try {
                var data = JSON.parse(raw)
                if (data && typeof data.maxResponseSize === "number" && data.maxResponseSize > 0) {
                    root.maxResponseSize = data.maxResponseSize
                    root.source = data.source || "pam-limits.json"
                    log()
                    return
                }
                root.source = "pam-limits.json has no positive maxResponseSize"
            } catch (e) {
                root.source = "pam-limits.json unparseable"
                console.warn("PamLimits: failed to parse", limitsPath, ":", e)
            }
        } else {
            root.source = "pam-limits.json missing"
        }
        log()
    }

    function log() {
        if (root.maxResponseSize > 0) {
            console.log("aerial-lock: PAM_MAX_RESP_SIZE=" + root.maxResponseSize
                        + " (source: " + root.source + ")")
        } else {
            console.warn("aerial-lock: PAM response size unknown (" + root.source
                         + ") — password field uncapped; run make to derive it")
        }
    }
}
