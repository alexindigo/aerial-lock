import QtQuick

// LockContext (d38/d40) — the one contract between the lock and its panel,
// and the exact same object themes (ours or the user's) receive. Data +
// callbacks only: no pixels, no PAM, no video-plugin imports. Lock.qml
// (the assembler) owns the bindings; submit/dismiss are signals so this
// type never imports its consumers.
//
// All strings are "" and numbers 0/-1 when unknown. Presentation
// projections (panel/colors/labels) mirror the shipped defaults so the
// context is sane even before Lock.qml binds them.
QtObject {
    id: root

    // The only unlock path a theme ever calls; Lock.qml connects it to
    // the same function the built-in panel used (tryUnlock). Zero
    // arguments (d43): the response comes from auth.input, the shared
    // draft — a widget never supplies a password.
    signal submitRequested()
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
        // Build-gated debug dismiss availability (d40 projection) —
        // themes render no dismiss affordance when false.
        property bool dismissAvailable: false

        // d43: the one authoritative editable-response record (draft,
        // selection, tuning profile/progress, writer handoff). The shared
        // AuthField core edits and renders this; submission consumes it.
        property alias input: inputObj
        property AuthInputState _inputObj: AuthInputState {
            id: inputObj
        }

        function submit() { root.submitRequested() }
        function dismiss() { root.dismissRequested() }
    }

    property alias clock: clockObj
    property QtObject _clockObj: QtObject {
        id: clockObj
        property string time: ""
        property string date: ""
        property string timezone: ""
        // d40: the wall clock itself. Themes format long dates, split
        // hours/minutes, and compute ring targets from `now` — never by
        // parsing the locale-short strings or running their own timers.
        property date now: new Date(0)
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
        // d45: the frame's sensed prominent color (transparent when
        // unsensed). Data only — the context never touches pixels; the
        // sampler lives in LockBackground and Lock.qml owns the binding.
        property color accent: "transparent"
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
        // d40: the selected session login (the PAM user) and the local
        // avatar file path. No AccountsService/NSS/network identity
        // lookup; missing imagery falls back to drawn initials.
        property string loginName: ""
        property string avatarPath: ""
    }

    // d40 presentation projections: the shipped panel metrics, colors and
    // translated labels, so themes and the reusable panel need neither
    // ConfigStore nor Logger. Read-only data — no new actions.
    property alias panel: panelObj
    property QtObject _panelObj: QtObject {
        id: panelObj
        property int widthMax: 360
        property int fieldHeight: 40
        property int radius: 12
        property int fieldRadius: 8
        property int outerMargin: 20
        property int spacing: 12
        property int fontSize: 16
    }

    property alias colors: colorsObj
    property QtObject _colorsObj: QtObject {
        id: colorsObj
        property string text: "#dddddd"
        property string textError: "#ff5555"
        property string input: "#ffffff"
        property string panelFill: "#14ffffff"
        property string panelBorder: "#1fffffff"
        property string fieldFill: "#0fffffff"
        property string fieldBorderFocused: "#40ffffff"
        property string fieldBorder: "#1affffff"
    }

    property alias labels: labelsObj
    property QtObject _labelsObj: QtObject {
        id: labelsObj
        property string prompt: "Enter password"
        property string authenticating: "Authenticating..."
        property string authFailed: "Authentication failed"
        property string maxTries: "Too many attempts"
        property string authError: "Authentication error"
        property string timedOut: "Authentication timed out — try again"
        property string dismissDebug: "Dismiss (debug)"
        property string unlocked: "Unlocked"
    }

    function updateClock() {
        var now = new Date()
        var loc = Qt.locale()
        clock.now = now
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
