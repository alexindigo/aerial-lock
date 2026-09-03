import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property int maxResponseSize: 512
    property string source: "fallback"
    property bool loaded: false

    readonly property string limitsPath: Quickshell.shellDir + "/Config/pam-limits.json"

    readonly property string cHeaderSource: "c-header from /usr/include/security/_pam_types.h at build time"
    readonly property string overrideSource: "build-override, forced via make PAM_MAX_RESP_SIZE"
    readonly property string fallbackSource: "fallback, pam-limits.json corrupt or missing"

    FileView {
        id: limitsFile
        path: limitsPath
        printErrors: false
    }

    Component.onCompleted: {
        limitsFile.waitForJob()
        var raw = limitsFile.text()
        if (raw && raw.length > 0) {
            try {
                var data = JSON.parse(raw)
                if (data && typeof data.maxResponseSize === "number" && data.maxResponseSize > 0) {
                    root.maxResponseSize = data.maxResponseSize
                    root.source = data.source || "fallback"
                    root.loaded = true
                    log()
                    return
                }
            } catch (e) {
                console.warn("PamLimits: failed to parse", limitsPath, ":", e)
            }
        }
        root.maxResponseSize = 256
        root.source = fallbackSource
        root.loaded = true
        log()
    }

    function log() {
        var msg = "PAM_MAX_RESP_SIZE=" + root.maxResponseSize + " (source: " + root.source + ")"
        if (root.source.startsWith("c-header") && root.maxResponseSize !== 512) {
            msg += " — differs from Linux-PAM default (512)"
        }
        if (root.source.startsWith("fallback")) {
            msg += " — rebuild: make clean && make, or force: make PAM_MAX_RESP_SIZE=<n>"
        }
        console.log("aerial-lock:", msg)
    }
}
