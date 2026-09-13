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
        printErrors: false
    }

    Component.onCompleted: {
        serviceFile.waitForJob()
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
