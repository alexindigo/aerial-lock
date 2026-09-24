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
    readonly property alias buildFlags: buildFlagsObj

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
        sources: "array",
        pamService: "string",
        fallbackQuitMs: "number",
        pamWatchdogTimeoutMs: "number",
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

    BuildFlags {
        id: buildFlagsObj
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
            Logger.w("ConfigStore", "could not write user config.json: "
                     + FileViewError.toString(err))
        }
    }

    Component.onCompleted: {
        // waitForJob() returning false means no load was ever queued for the
        // path — a structural defect, not a slow disk. With blockLoading the
        // reads below are definitive either way: empty means genuinely missing
        // or unreadable, never "not loaded yet".
        if (!defaultsFile.waitForJob()) {
            Logger.w("ConfigStore", "no load job was queued for " + defaultsPath)
        }
        if (!userFile.waitForJob()) {
            Logger.w("ConfigStore", "no load job was queued for " + configPath)
        }
        buildFlagsObj.load()
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
                if (migrateUserConfig(user)) {
                    userFile.setText(JSON.stringify(user, null, 2) + "\n")
                }
                merged = deepMerge(defaults, user)
                sanitise(merged, defaults, root.schema, "")
                merged.sources = cleanSources(merged.sources)
                validatePreferred(merged)
            } catch (e) {
                Logger.w("ConfigStore", "user config.json parse error (" + e + "); using defaults")
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
            Logger.w("ConfigStore", "no load job was queued for " + i18nFile.path)
        }
        var raw = i18nFile.text()
        if (raw && raw.length > 0) {
            try {
                root.i18n = JSON.parse(raw)
                return
            } catch (e) {
                Logger.w("ConfigStore", "i18n file parse error for " + lang + " (" + e + ")")
            }
        }

        if (lang === "en") {
            root.i18n = {}
            return
        }

        Logger.w("ConfigStore", "i18n file not found for " + lang + "; trying en fallback")
        i18nFile.path = i18nDir + "/en.json"
        if (!i18nFile.waitForJob()) {
            Logger.w("ConfigStore", "no load job was queued for " + i18nFile.path)
        }
        raw = i18nFile.text()
        if (raw && raw.length > 0) {
            try {
                root.i18n = JSON.parse(raw)
                return
            } catch (e) {
                Logger.w("ConfigStore", "en fallback i18n parse error (" + e + ")")
            }
        }

        root.i18n = {}
    }

    function isPlainObject(v) {
        return v !== null && typeof v === "object" && !Array.isArray(v)
    }

    // d36: source name → cache directory name (spaces to '-', everything
    // outside [A-Za-z0-9._-] stripped). The fetch script implements the
    // same rule — they must stay identical.
    function sanitizeSourceName(name) {
        return name.replace(/ /g, "-").replace(/[^A-Za-z0-9._-]/g, "")
    }

    // Per-entry tolerance (d17 spirit): a bad entry is dropped with a
    // warning naming its index; the rest of the list is kept. Each
    // surviving entry gains a `safeName` for cache-dir use. A source with
    // an invalid resolution band (min/max not 1080/2160) is dropped
    // entirely — fetch skips it the same way.
    function cleanSources(list) {
        var out = []
        var seen = ({})
        for (var i = 0; i < list.length; i++) {
            var s = list[i]
            if (!isPlainObject(s) || typeof s.type !== "string" || s.type.length === 0
                    || typeof s.name !== "string" || s.name.length === 0
                    || typeof s.source !== "string" || s.source.length === 0) {
                Logger.w("ConfigStore", "sources[" + i + "] needs type/name/source strings; entry dropped")
                continue
            }
            if (["apple", "community", "folder", "file"].indexOf(s.type) === -1) {
                Logger.w("ConfigStore", "sources[" + i + "].type \"" + s.type + "\" unknown; entry dropped")
                continue
            }
            var bandBad = false
            for (var b = 0; b < 2; b++) {
                var key = b === 0 ? "minResolution" : "maxResolution"
                var v = s[key]
                if (v !== undefined && (typeof v !== "number" || (v !== 1080 && v !== 2160))) {
                    Logger.w("ConfigStore", "sources[" + i + "]." + key + " must be 1080 or 2160; entry dropped")
                    bandBad = true
                }
            }
            if (bandBad)
                continue
            var safe = sanitizeSourceName(s.name)
            if (safe.length === 0) {
                Logger.w("ConfigStore", "sources[" + i + "].name sanitizes to nothing; entry dropped")
                continue
            }
            if (seen[safe]) {
                Logger.w("ConfigStore", "sources[" + i + "] duplicates cache name \"" + safe + "\"; later entry dropped")
                continue
            }
            seen[safe] = true
            var entry = { type: s.type, name: s.name, safeName: safe, source: s.source }
            if (s.minResolution !== undefined) entry.minResolution = s.minResolution
            if (s.maxResolution !== undefined) entry.maxResolution = s.maxResolution
            out.push(entry)
        }
        return out
    }

    // d37 existence-write: stamp preferredResolution (1080 or 2160) into
    // the user config — but ONLY if the key is absent from the file on
    // disk. A key already there is never touched, even one sanitise
    // dropped from `data` (e.g. 1440): "key present in the user file"
    // is what counts, not the sanitised value.
    function maybeWritePreferred(n) {
        if (n !== 1080 && n !== 2160)
            return false
        var raw = userFile.text()
        var user = ({})
        if (raw && raw.length > 0) {
            try { user = JSON.parse(raw) } catch (e) {
                Logger.w("ConfigStore", "maybeWritePreferred: user config unparseable; not writing")
                return false
            }
        }
        if ("preferredResolution" in user)
            return false
        user.preferredResolution = n
        Logger.w("ConfigStore", "stamped preferredResolution " + n + " into " + configPath)
        userFile.setText(JSON.stringify(user, null, 2) + "\n")
        return true
    }

    // d37: preferredResolution is optional and NOT in the bundle defaults —
    // absence is the signal fetch/Lock use for the existence-write. A
    // present-but-invalid value is dropped from data with a warning; the
    // user file on disk stays untouched (that's maybeWritePreferred's cue
    // that a key exists at all).
    function validatePreferred(data) {
        if (!("preferredResolution" in data))
            return
        var v = data.preferredResolution
        if (typeof v !== "number" || (v !== 1080 && v !== 2160)) {
            Logger.w("ConfigStore", "preferredResolution must be 1080 or 2160 (got "
                     + JSON.stringify(v) + "); ignoring — file unchanged")
            delete data.preferredResolution
        }
    }

    // d36 one-shot migration: a user config with the d32/d35 keys and no
    // `sources` gets them rewritten into entries, written back once.
    function migrateUserConfig(user) {
        if ("sources" in user)
            return false
        if (!("video" in user) && !("videoDir" in user) && !("apple" in user))
            return false
        var migrated = []
        if (typeof user.video === "string" && user.video.length > 0)
            migrated.push({ type: "file", name: "video", source: user.video })
        if (typeof user.videoDir === "string" && user.videoDir.length > 0)
            migrated.push({ type: "folder", name: "videoDir", source: user.videoDir })
        if (isPlainObject(user.apple) && user.apple.enabled === true)
            migrated.push({ type: "apple", name: "Apple TV",
                            source: "https://sylvan.apple.com/Aerials/resources-16.tar" })
        user.sources = migrated
        delete user.video
        delete user.videoDir
        delete user.apple
        Logger.w("ConfigStore", "migrated video/videoDir/apple to sources[]")
        return true
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
            } else if (spec[key] === "array") {
                if (!Array.isArray(candidate[key])) {
                    Logger.w("ConfigStore", fullPath + " has wrong type (expected array, got "
                             + typeof candidate[key] + "); using default")
                    candidate[key] = defaults[key]
                }
            } else if (typeof candidate[key] !== spec[key]) {
                Logger.w("ConfigStore", fullPath + " has wrong type (expected "
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
                Logger.w("ConfigStore", fullPath + " has wrong type (expected "
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
                    Logger.w("ConfigStore", "bundle defaults invalid at " + fullPath)
                    return false
                }
            } else if (spec[key] === "array") {
                if (!Array.isArray(data[key])) {
                    Logger.w("ConfigStore", "bundle defaults invalid at " + fullPath
                             + " (expected array)")
                    return false
                }
            } else if (typeof data[key] !== spec[key]) {
                Logger.w("ConfigStore", "bundle defaults invalid at " + fullPath
                         + " (expected " + spec[key] + ", got " + typeof data[key] + ")")
                return false
            }
        }
        return true
    }

    function fail(msg) {
        Logger.w("ConfigStore", "FAILED: " + msg)
        errorMessage = msg
        failed = true
    }
}
