import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    required property string service
    required property string configDirectory

    property bool checked: false
    property bool ok: false
    property string reason: ""

    readonly property string servicePath: configDirectory + "/" + service

    FileView {
        id: serviceFile
        path: root.servicePath
        blockLoading: true
        printErrors: false
    }

    Component.onCompleted: {
        // A false return means no load job was queued for the path at all;
        // with blockLoading the read is then definitive rather than possibly
        // still in flight — an empty read here must never be a timing artifact
        // (it gates the refuse-to-lock decision).
        if (!serviceFile.waitForJob()) {
            console.warn("PamProbe: no load job was queued for", root.servicePath)
        }
        var raw = serviceFile.text()
        if (raw && raw.length > 0) {
            root.ok = true
        } else {
            root.ok = false
            root.reason = "PAM service file missing or unreadable: " + root.servicePath
        }
        root.checked = true
    }
}
