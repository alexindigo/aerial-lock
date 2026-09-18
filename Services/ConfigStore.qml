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
        fallbackQuitMs: "number",
        pamWatchdogTimeoutMs: "number",
        debugAllowDismiss: "boolean",
        panel: ({
            widthMax: "number",
            fieldHeight: "number",
            radius: "number",
            fieldRadius: "number",
            outerMargin: "number",
            spacing: "number",
            fontSize: "number"
        }),
        colors: ({
            text: "string",
            textError: "string",
            input: "string",
            panelFill: "string",
            panelBorder: "string",
            fieldFill: "string",
            fieldBorderFocused: "string",
            fieldBorder: "string"
        })
    })

    PamLimits {
        id: pamLimitsObj
    }

    FileView {
        id: defaultsFile
        path: defaultsPath
        blockLoading: true
        printErrors: true
    }

    FileView {
        id: i18nFile
        path: ""
        blockLoading: true
        printErrors: false
    }

    FileView {
        id: userFile
        path: configPath
        blockLoading: true
        atomicWrites: true
        printErrors: false

        onSaveFailed: function (err) {
            console.warn("ConfigStore: could not write user config.json:",
                         FileViewError.toString(err))
        }
    }

    Component.onCompleted: {
        // waitForJob() returning false means no load was ever queued for the
        // path — a structural defect, not a slow disk. With blockLoading the
        // reads below are definitive either way: empty means genuinely missing
        // or unreadable, never "not loaded yet".
        if (!defaultsFile.waitForJob()) {
            console.warn("ConfigStore: no load job was queued for", defaultsPath)
        }
        if (!userFile.waitForJob()) {
            console.warn("ConfigStore: no load job was queued for", configPath)
        }
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

        if (!checkBundle(defaults, root.schema, "")) {
            fail("Bundle defaults.json failed schema validation")
            return
        }

        var merged = defaults

        var userRaw = userFile.text()
        if (userRaw && userRaw.length > 0) {
            try {
                var user = JSON.parse(userRaw)
                merged = deepMerge(defaults, user)
                sanitise(merged, defaults, root.schema, "")
            } catch (e) {
                console.warn("ConfigStore: user config.json parse error (" + e + "); using defaults")
                merged = defaults
            }
        } else {
            // First launch: seed the user config with the shipped defaults.
            // FileView's writer creates missing parent directories itself
            // (FileViewWriter::write() mkpaths), so no mkdir scaffolding;
            // a failed write surfaces via onSaveFailed above.
            userFile.setText(defaultsRaw)
        }

        loadI18n(merged.language || "en")
        root.data = merged
        root.ready = true
    }

    function loadI18n(lang) {
        i18nFile.path = i18nDir + "/" + lang + ".json"
        if (!i18nFile.waitForJob()) {
            console.warn("ConfigStore: no load job was queued for", i18nFile.path)
        }
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
        if (!i18nFile.waitForJob()) {
            console.warn("ConfigStore: no load job was queued for", i18nFile.path)
        }
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

    function isPlainObject(v) {
        return v !== null && typeof v === "object" && !Array.isArray(v)
    }

    // Every base key exists in the result; an override wins leaf-by-leaf,
    // recursing only when both sides are plain objects. Unknown override
    // keys are carried but unread.
    function deepMerge(base, override) {
        var result = {}
        for (var key in base) result[key] = base[key]
        for (var okey in override) {
            if (isPlainObject(base[okey]) && isPlainObject(override[okey])) {
                result[okey] = deepMerge(base[okey], override[okey])
            } else {
                result[okey] = override[okey]
            }
        }
        return result
    }

    // Per-field type repair, never whole-config rejection: a wrong-typed
    // value falls back to its own default with a warning naming the path.
    function sanitise(candidate, defaults, spec, path) {
        for (var key in spec) {
            var fullPath = path === "" ? key : path + "." + key
            if (isPlainObject(spec[key])) {
                if (isPlainObject(candidate[key])) {
                    sanitise(candidate[key], defaults[key], spec[key], fullPath)
                } else {
                    warnSubtree(spec[key], fullPath)
                    candidate[key] = defaults[key]
                }
            } else if (typeof candidate[key] !== spec[key]) {
                console.warn("ConfigStore: " + fullPath + " has wrong type (expected "
                             + spec[key] + ", got " + typeof candidate[key] + "); using default")
                candidate[key] = defaults[key]
            }
        }
    }

    function warnSubtree(spec, path) {
        for (var key in spec) {
            var fullPath = path + "." + key
            if (isPlainObject(spec[key])) {
                warnSubtree(spec[key], fullPath)
            } else {
                console.warn("ConfigStore: " + fullPath + " has wrong type (expected "
                             + spec[key] + "); using default")
            }
        }
    }

    // Bundle defaults are ours: a broken defaults.json is a build bug, so it
    // still fails closed rather than limping along half-initialised.
    function checkBundle(data, spec, path) {
        for (var key in spec) {
            var fullPath = path === "" ? key : path + "." + key
            if (isPlainObject(spec[key])) {
                if (!isPlainObject(data[key]) || !checkBundle(data[key], spec[key], fullPath)) {
                    console.warn("ConfigStore: bundle defaults invalid at " + fullPath)
                    return false
                }
            } else if (typeof data[key] !== spec[key]) {
                console.warn("ConfigStore: bundle defaults invalid at " + fullPath
                             + " (expected " + spec[key] + ", got " + typeof data[key] + ")")
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
