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
    property bool loaded: false

    readonly property string flagsPath: Quickshell.shellDir + "/Config/build-flags.json"

    FileView {
        id: flagsFile
        path: flagsPath
        blockLoading: true
        printErrors: false
    }

    Component.onCompleted: load()

    function load() {
        if (loaded)
            return
        loaded = true
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
        if (root.debugAllowDismiss) {
            console.warn("aerial-lock: DEBUG DISMISS ENABLED — this build unlocks"
                         + " WITHOUT authentication (make dev builds only)")
        }
    }
}
