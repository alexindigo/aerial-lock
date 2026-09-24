import QtQml
import QtQuick
import Quickshell
import Quickshell.Io

// Playlist resolution for the lock background (d36). Walks config
// sources[] in order and emits items: file → the clip, folder → the
// directory (~ and $HOME expanded), apple/community → the cache's
// videos/ dir, but only when its entries.json sentinel has text — a
// never-fetched source is skipped, not an error. Missing file/folder
// paths are left to mpv (it errors and advances; no crash). The locker
// never fetches anything.
Scope {
    id: root

    required property ConfigStore config

    // [{kind: "file"|"dir", path: "…"}, …] in sources[] order.
    property var items: []

    readonly property string cacheBase: {
        var xdg = Quickshell.env("XDG_CACHE_HOME")
        if (xdg && xdg.length > 0) return xdg + "/aerial-lock"
        var home = Quickshell.env("HOME")
        return home ? home + "/.cache/aerial-lock" : ""
    }

    readonly property var sources: config.data.sources || []

    readonly property var remoteSources: {
        var out = []
        for (var i = 0; i < sources.length; i++)
            if (sources[i].type === "apple" || sources[i].type === "community")
                out.push(sources[i])
        return out
    }

    function expandHome(p) {
        var home = Quickshell.env("HOME")
        if (p === "~") return home
        if (p.startsWith("~/")) return home + p.slice(1)
        if (p.startsWith("$HOME")) return home + p.slice(5)
        return p
    }

    function sentinelVideosDir(safeName) {
        for (var i = 0; i < sentinels.count; i++) {
            var o = sentinels.objectAt(i)
            // qmllint disable missing-property
            // objectAt() is typed QObject; the delegates are the Item
            // above carrying safeName/sentinelText — dynamic by design.
            if (o && o.safeName === safeName)
                return o.sentinelText.length > 0 ? cacheBase + "/" + safeName + "/videos" : ""
            // qmllint enable missing-property
        }
        return ""
    }

    function sentinelTextFor(safeName) {
        for (var i = 0; i < sentinels.count; i++) {
            var o = sentinels.objectAt(i)
            // qmllint disable missing-property
            if (o && o.safeName === safeName)
                return o.sentinelText
            // qmllint enable missing-property
        }
        return ""
    }

    // d38: resolve a playing path to its source + manifest metadata.
    // Returns null when the path belongs to no configured source. Manifest
    // fields (name/scene/timeOfDay/…) are "" when the source has no
    // entries.json for it (file/folder, or an unfetched remote). Apple POI
    // values are strings-bundle keys, not prose — poi is only filled for
    // community packs this plan (d38 §3 deferral, no C++ plist parser).
    property var _entriesCache: ({})   // safeName → parsed entries.json

    function _entriesFor(safeName) {
        if (_entriesCache[safeName] !== undefined)
            return _entriesCache[safeName]
        var parsed = null
        var raw = sentinelTextFor(safeName)
        if (raw.length > 0) {
            try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
        }
        _entriesCache[safeName] = parsed
        return parsed
    }

    function lookup(path) {
        if (!path || path.length === 0)
            return null
        var base = path.split("/").pop()
        var id = base.replace(/\.[^.]+$/, "")
        for (var i = 0; i < sources.length; i++) {
            var src = sources[i]
            if (src.type === "file") {
                if (expandHome(src.source) !== path)
                    continue
                return { id: id, sourceName: src.name }
            } else if (src.type === "folder") {
                var dir = expandHome(src.source)
                if (path !== dir && !path.startsWith(dir + "/"))
                    continue
                return { id: id, sourceName: src.name }
            } else {
                var prefix = cacheBase + "/" + src.safeName + "/videos/"
                if (!path.startsWith(prefix))
                    continue
                var entries = _entriesFor(src.safeName)
                var info = { id: id, sourceName: src.name }
                var assets = entries ? entries.assets : null
                if (assets) {
                    for (var a = 0; a < assets.length; a++) {
                        if (assets[a].id === id) {
                            info.name = assets[a].accessibilityLabel || ""
                            info.secondaryName = assets[a].title || ""
                            info.scene = assets[a].scene || ""
                            info.timeOfDay = assets[a].timeOfDay || ""
                            if (src.type === "community")
                                info.poi = assets[a].pointsOfInterest || ({})
                            break
                        }
                    }
                }
                return info
            }
        }
        return null
    }

    function recompute() {
        var out = []
        for (var i = 0; i < sources.length; i++) {
            var src = sources[i]
            if (src.type === "file") {
                out.push({ kind: "file", path: expandHome(src.source) })
            } else if (src.type === "folder") {
                out.push({ kind: "dir", path: expandHome(src.source) })
            } else {
                var dir = sentinelVideosDir(src.safeName)
                if (dir.length > 0)
                    out.push({ kind: "dir", path: dir })
            }
        }
        items = out
    }

    // One sentinel FileView per remote source; a missing cache reads as
    // empty text, not an error.
    Instantiator {
        id: sentinels
        model: root.remoteSources

        delegate: Item {
            id: sentinelDelegate
            required property var modelData
            readonly property string safeName: modelData.safeName
            readonly property string sentinelText: view.text()

            FileView {
                id: view
                path: root.cacheBase + "/" + sentinelDelegate.safeName + "/entries.json"
                blockLoading: true
                printErrors: false

                onTextChanged: root.recompute()
                onLoadFailed: root.recompute()
            }
        }

        onObjectAdded: root.recompute()
        onCountChanged: root.recompute()
    }

    Component.onCompleted: recompute()
}
