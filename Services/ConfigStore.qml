import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    property bool ready: false
    property bool failed: false
    property string errorMessage: ""

    property var data: ({})
    property var i18n: ({})

    readonly property alias pamLimits: pamLimitsObj

    readonly property string configDir: {
        var xdg = Quickshell.env("XDG_CONFIG_HOME")
        if (xdg && xdg.length > 0) return xdg + "/aerial-lock"
        var home = Quickshell.env("HOME")
        return home ? home + "/.config/aerial-lock" : ""
    }
    readonly property string configPath: configDir + "/config.json"
    readonly property string defaultsPath: Quickshell.shellDir + "/Config/defaults.json"
    readonly property string i18nDir: Quickshell.shellDir + "/Config/i18n"

    readonly property string pamService: {
        var override = Quickshell.env("AERIAL_LOCK_PAM_SERVICE")
        if (override && override.length > 0) return override
        return (data && data.pamService) ? data.pamService : "aerial-lock"
    }
    readonly property string pamConfigDirectory: "/etc/pam.d"

    readonly property var schema: ({
        language: "string",
        backgroundColor: "string",
        pamService: "string",
        fadeMs: "number",
        fallbackQuitMs: "number",
        debugAllowDismiss: "boolean",
        panel: "object",
        colors: "object"
    })

    PamLimits {
        id: pamLimitsObj
    }

    FileView {
        id: defaultsFile
        path: defaultsPath
        printErrors: true
    }

    FileView {
        id: i18nFile
        path: ""
        printErrors: false
    }

    FileView {
        id: userFile
        path: configPath
        atomicWrites: true
        printErrors: false

        onSaveFailed: function (err) {
            console.warn("ConfigStore: could not write user config.json:",
                         FileViewError.toString(err))
        }
    }

    Process {
        id: ensureDirProc
        running: false
        command: ["mkdir", "-p", root.configDir]
        onExited: function (code, status) {
            if (code === 0) {
                userFile.setText(root.pendingWrite)
            } else {
                console.warn("ConfigStore: mkdir -p failed for", root.configDir)
            }
        }
    }

    property string pendingWrite: ""

    Component.onCompleted: {
        defaultsFile.waitForJob()
        userFile.waitForJob()
        initialize()
    }

    function initialize() {
        var defaultsRaw = defaultsFile.text()
        if (!defaultsRaw || defaultsRaw.length === 0) {
            fail("Bundle defaults.json missing or empty at " + defaultsPath)
            return
        }

        var defaults
        try { defaults = JSON.parse(defaultsRaw) } catch (e) {
            fail("Bundle defaults.json parse error: " + e)
            return
        }

        if (!validateSchema(defaults)) {
            fail("Bundle defaults.json failed schema validation")
            return
        }

        var merged = Object.assign({}, defaults)

        var userRaw = userFile.text()
        if (userRaw && userRaw.length > 0) {
            try {
                var user = JSON.parse(userRaw)
                var candidate = Object.assign({}, defaults, user)
                if (validateSchema(candidate)) {
                    merged = candidate
                } else {
                    console.warn("ConfigStore: user config.json failed schema validation; using defaults")
                }
            } catch (e) {
                console.warn("ConfigStore: user config.json parse error (" + e + "); using defaults")
            }
        } else {
            pendingWrite = defaultsRaw
            ensureDirProc.running = true
        }

        loadI18n(merged.language || "en")
        root.data = merged
        root.ready = true
    }

    function loadI18n(lang) {
        i18nFile.path = i18nDir + "/" + lang + ".json"
        i18nFile.waitForJob()
        var raw = i18nFile.text()
        if (raw && raw.length > 0) {
            try {
                root.i18n = JSON.parse(raw)
                return
            } catch (e) {
                console.warn("ConfigStore: i18n file parse error for " + lang + " (" + e + ")")
            }
        }

        if (lang === "en") {
            root.i18n = {}
            return
        }

        console.warn("ConfigStore: i18n file not found for " + lang + "; trying en fallback")
        i18nFile.path = i18nDir + "/en.json"
        i18nFile.waitForJob()
        raw = i18nFile.text()
        if (raw && raw.length > 0) {
            try {
                root.i18n = JSON.parse(raw)
                return
            } catch (e) {
                console.warn("ConfigStore: en fallback i18n parse error (" + e + ")")
            }
        }

        root.i18n = {}
    }

    function validateSchema(data) {
        for (var key in root.schema) {
            if (!(key in data)) {
                console.warn("ConfigStore: schema validation — missing field: " + key)
                return false
            }
            var expected = root.schema[key]
            var actual = typeof data[key]
            if (expected === "boolean") {
                if (actual !== "boolean") {
                    console.warn("ConfigStore: schema validation — field " + key +
                                 " has wrong type (expected boolean)")
                    return false
                }
            } else if (actual !== expected) {
                console.warn("ConfigStore: schema validation — field " + key +
                             " has wrong type (expected " + expected + ", got " + actual + ")")
                return false
            }
        }
        return true
    }

    function fail(msg) {
        console.warn("ConfigStore FAILED:", msg)
        errorMessage = msg
        failed = true
    }
}
