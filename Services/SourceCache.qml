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
