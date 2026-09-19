import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    // Both default false, and the failure posture is inverted from PamLimits:
    // a missing or corrupt build-flags.json yields a build with no bypass and
    // no chatter, never an enabled one. Failing secure is the whole point.
    property bool debugAllowDismiss: false
    property bool verbose: false

    readonly property string flagsPath: Quickshell.shellDir + "/Config/build-flags.json"

    FileView {
        id: flagsFile
        path: flagsPath
        blockLoading: true
        printErrors: false
    }

    Component.onCompleted: {
        // d18 pattern: a false return means no load job was queued at all;
        // with blockLoading the read below is definitive either way.
        if (!flagsFile.waitForJob()) {
            console.warn("BuildFlags: no load job was queued for", flagsPath)
        }
        var raw = flagsFile.text()
        if (raw && raw.length > 0) {
            try {
                var data = JSON.parse(raw)
                if (data && typeof data.debugAllowDismiss === "boolean"
                        && typeof data.verbose === "boolean") {
                    root.debugAllowDismiss = data.debugAllowDismiss
                    root.verbose = data.verbose
                } else {
                    console.warn("BuildFlags:", flagsPath,
                                 "lacks boolean debugAllowDismiss/verbose; flags stay off")
                }
            } catch (e) {
                console.warn("BuildFlags: failed to parse", flagsPath, ":", e)
            }
        }
        // A build that unlocks without a password must be impossible to run
        // unknowingly.
        if (root.debugAllowDismiss) {
            console.warn("aerial-lock: DEBUG DISMISS ENABLED — this build unlocks"
                         + " WITHOUT authentication (make dev builds only)")
        }
    }
}
