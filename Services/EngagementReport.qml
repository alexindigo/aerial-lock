import QtQuick
import Quickshell
import Quickshell.Io

// Reports this locker's actual engagement to the supervisor that launched it.
// The supervisor owns the channel (a private Unix socket it accepts only from
// this process) and passes its path in AERIAL_LOCK_ENGAGEMENT_SOCKET; without
// one (an unsupervised development run) nothing is reported.
//
// Protocol: while `secure` — the compositor's ext-session-lock `locked`
// confirmation — holds, keep one connection open after sending "locked\n".
// Closing it (secure lost, unlock, teardown, exit) withdraws the confirmation.
Scope {
    id: root

    required property string path
    required property bool secure
    signal releaseRequested()
    property bool warnedUnknownCommand: false

    function readCommand(line) {
        if (line === "release") {
            root.releaseRequested()
        } else if (!root.warnedUnknownCommand) {
            root.warnedUnknownCommand = true
            console.warn("EngagementReport: ignored an unknown supervisor command")
        }
    }

    Socket {
        id: channel
        objectName: "engagementReportChannel"
        path: root.path
        connected: root.secure && root.path.length > 0
        parser: SplitParser {
            objectName: "engagementReportParser"
            onRead: line => root.readCommand(line)
        }
        onConnectedChanged: {
            if (channel.connected) {
                channel.write("locked\n")
                channel.flush()
            }
        }
    }
}
