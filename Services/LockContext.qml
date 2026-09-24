import QtQuick

// LockContext (d38) — the one contract between the lock and its panel,
// and the exact same object future themes (ours or the user's) receive.
// Data + callbacks only: no pixels, no PAM, no video-plugin imports.
// Lock.qml (the assembler) owns the bindings; submit/dismiss are signals
// so this type never imports its consumers.
//
// All strings are "" and numbers 0/-1 when unknown.
QtObject {
    id: root

    // The only unlock path a theme ever calls; Lock.qml connects it to
    // the same function the built-in panel used (tryUnlock).
    signal submitRequested(string password)
    // Debug dismiss — Lock.qml no-ops it unless debugAllowDismiss.
    signal dismissRequested()

    property alias auth: authObj
    property QtObject _authObj: QtObject {
        id: authObj
        property string status: ""
        property bool inProgress: false
        property bool isError: false
        property bool responseVisible: false
        property int maxResponseSize: 0

        function submit(password) { root.submitRequested(password) }
        function dismiss() { root.dismissRequested() }
    }

    property alias clock: clockObj
    property QtObject _clockObj: QtObject {
        id: clockObj
        property string time: ""
        property string date: ""
        property string timezone: ""
    }

    property alias video: videoObj
    property QtObject _videoObj: QtObject {
        id: videoObj
        property string id: ""             // asset id (cache filename stem)
        property string name: ""           // accessibilityLabel, else ""
        property string secondaryName: ""
        property string scene: ""
        property string timeOfDay: ""
        property string sourceName: ""     // sources[].name it came from
        property string path: ""           // current filename / source path
        property real position: 0          // seconds
        property real duration: 0
        property bool hasVideo: false
    }

    property alias poi: poiObj
    property QtObject _poiObj: QtObject {
        id: poiObj
        property string text: ""           // caption at position, or ""
        property real at: -1               // that caption's timestamp
        // {seconds-as-string: caption} for the current video; set by
        // Lock.qml from SourceCache's manifest lookup. Community packs
        // carry prose; Apple carries keys into the strings bundle, which
        // stays unresolved this plan (no C++ plist parser — d38 §3).
        property var map: ({})
    }

    property alias session: sessionObj
    property QtObject _sessionObj: QtObject {
        id: sessionObj
        // No documented Qt/compositor QML API exposes the keyboard layout
        // name (checked Qt + Quickshell niri/Hyprland services, d38) — ""
        // until one exists. No setxkbmap//proc scraping.
        property string layout: ""
        property string outputName: ""     // focused output
    }

    function updateClock() {
        var now = new Date()
        var loc = Qt.locale()
        clock.time = now.toLocaleTimeString(loc, Locale.ShortFormat)
        clock.date = now.toLocaleDateString(loc, Locale.ShortFormat)
        clock.timezone = Qt.formatTime(now, "t")
    }

    property Timer _clockTimer: Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.updateClock()
    }

    Component.onCompleted: updateClock()
}
