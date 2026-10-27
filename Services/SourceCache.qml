import QtQml
import QtQuick
import Quickshell
import Quickshell.Io
import Qt.labs.folderlistmodel
import "ThemeSelection.js" as ThemeSelection

// Playlist resolution for the lock background (d36/d40). Walks config
// sources[] in order and, per source, enumerates an explicit clip
// inventory — file → the clip, folder → its videos (extension rules
// retained), apple/community → cache clips that exist, are nonempty, and
// carry the sibling .mp4.done marker (entries.json is a catalog, never
// proof of download; this closes the partial-download dir-expansion hole).
//
// Everything is nonblocking: FolderListModel per directory source, one
// nonblocking FileView per remote manifest, a 2000 ms deadline from
// begin(). The resolved snapshot is published ONCE per lock (frozen);
// theme topics select a matching subset in original order, else the full
// pool. The locker never fetches anything.
Scope {
    id: root

    required property ConfigStore config

    // d40: the theme's declared preference (from ThemeHost via Lock.qml),
    // assigned before begin(). [] = no preference → regular pool.
    property var topics: []

    // Frozen per-lock snapshot for Lock.qml, in {kind:"file", path} shape.
    readonly property var playlist: internal.playlist
    readonly property bool resolved: internal.resolved

    QtObject {
        id: internal
        property var playlist: []
        property bool resolved: false
    }

    readonly property string cacheBase: {
        var xdg = Quickshell.env("XDG_CACHE_HOME")
        if (xdg && xdg.length > 0) return xdg + "/aerial-lock"
        var home = Quickshell.env("HOME")
        return home ? home + "/.cache/aerial-lock" : ""
    }

    readonly property var sources: config.data.sources || []
    readonly property var vidFilters: ["*.mp4", "*.mkv", "*.webm", "*.mov"]

    // Parsed manifests per remote source (safeName → parsed entries.json),
    // filled by nonblocking reads. lookup() reads this at runtime.
    property var _manifests: ({})

    function expandHome(p) {
        var home = Quickshell.env("HOME")
        if (p === "~") return home
        if (p.startsWith("~/")) return home + p.slice(1)
        if (p.startsWith("$HOME")) return home + p.slice(5)
        return p
    }

    function stemOf(path) {
        var base = path.split("/").pop()
        return base.replace(/\.[^.]+$/, "")
    }

    // ---- begin / deadline / publish -------------------------------------

    property bool _begun: false

    // Called by Lock.qml once theme topics are known. Idempotent.
    function begin() {
        if (_begun)
            return
        _begun = true
        deadline.start()
        checkAllDone()
    }

    Timer {
        id: deadline
        interval: 2000
        repeat: false
        onTriggered: root.publish(true)
    }

    function checkAllDone() {
        if (!_begun || internal.resolved)
            return
        for (var i = 0; i < inv.count; i++) {
            var o = inv.objectAt(i)
            // qmllint disable missing-property
            // objectAt() is typed QObject; the delegate below carries
            // done — dynamic by design.
            if (!o || !o.done) {
                // qmllint enable missing-property
                return
            }
        }
        publish(false)
    }

    function publish(timedOut) {
        if (internal.resolved)
            return
        deadline.stop()
        var inventory = []
        for (var i = 0; i < inv.count; i++) {
            var o = inv.objectAt(i)
            // qmllint disable missing-property
            // objectAt() is typed QObject; the delegates carry done/clips/
            // srcName — dynamic by design.
            if (!o)
                continue
            if (!o.done) {
                if (timedOut)
                    Logger.w("SourceCache", "source \"" + o.srcName + "\" did not resolve in time; no clips from it this lock")
                continue
            }
            for (var j = 0; j < o.clips.length; j++)
                inventory.push(o.clips[j])
            // qmllint enable missing-property
        }
        var sel = ThemeSelection.selectPlaylist(inventory, root.topics)
        var out = []
        for (var k = 0; k < sel.length; k++)
            out.push({ kind: "file", path: sel[k] })
        internal.playlist = out
        internal.resolved = true
        if (timedOut)
            Logger.w("SourceCache", "inventory deadline hit; resolved with " + out.length + " clips")
        Logger.d("SourceCache", "resolved: " + out.length + " clips, topics=" + JSON.stringify(root.topics))
        var names = []
        for (var m = 0; m < out.length; m++)
            names.push(out[m].path.split("/").pop())
        Logger.d("SourceCache", "playlist: " + names.join(", "))
    }

    // ---- per-source inventory -------------------------------------------

    Instantiator {
        id: inv
        model: root.sources

        delegate: QtObject {
            id: del
            required property var modelData
            readonly property string srcType: modelData.type
            readonly property string srcName: modelData.name
            readonly property string safeName: modelData.safeName !== undefined ? modelData.safeName : ""
            readonly property bool isRemote: srcType === "apple" || srcType === "community"

            property var clips: []
            property bool done: false

            property bool _invReady: false
            property bool _manifestReady: false

            function finish(list) {
                clips = list
                done = true
                root.checkAllDone()
            }

            // file: the clip itself, matched on its filename stem.
            function resolveFile() {
                var p = root.expandHome(modelData.source)
                finish([{ path: p, matchText: root.stemOf(p) }])
            }

            // folder: the model's name-ordered (case-insensitive) videos,
            // matched on filename stems. Nonrecursive per FolderListModel.
            function collectFolder() {
                var out = []
                for (var i = 0; i < invModel.count; i++) {
                    var p = invModel.get(i, "filePath")
                    if (p && p.length > 0)
                        out.push({ path: p, matchText: root.stemOf(p) })
                }
                finish(out)
            }

            // remote: clips = stems having BOTH name.mp4 (nonempty) and
            // name.mp4.done in one inventory; matchText from the manifest
            // (label/title/scene) joined to the actual file — metadata
            // never invents paths, and unmarked/partial files never play.
            function collectRemote() {
                var mp4 = ({})
                var doneMarks = ({})
                for (var i = 0; i < invModel.count; i++) {
                    var name = invModel.get(i, "fileName")
                    var p = invModel.get(i, "filePath")
                    var size = invModel.get(i, "fileSize")
                    if (!name || !p)
                        continue
                    if (name.slice(-5) === ".done") {
                        doneMarks[name.slice(0, -5)] = true
                    } else if (name.slice(-4) === ".mp4" && size > 0) {
                        mp4[name] = p
                    }
                }
                var entries = root._manifests[del.safeName]
                var assets = entries ? entries.assets : null
                var out = []
                for (var fname in mp4) {
                    // doneMarks keys are the marker's stem ("aaa111.mp4"
                    // for "aaa111.mp4.done"); the clip name is the same.
                    if (!doneMarks[fname])
                        continue
                    var stem = root.stemOf(fname)
                    var matchText = ""
                    if (assets) {
                        for (var a = 0; a < assets.length; a++) {
                            if (assets[a].id === stem) {
                                matchText = (assets[a].accessibilityLabel || "") + " "
                                          + (assets[a].title || "") + " "
                                          + (assets[a].scene || "")
                                break
                            }
                        }
                    }
                    out.push({ path: mp4[fname], matchText: matchText, _stem: stem })
                }
                // FolderListModel sorts by name case-insensitively, but the
                // object built above lost that order — restore it by stem.
                out.sort(function (x, y) { var xl = x._stem.toLowerCase(), yl = y._stem.toLowerCase(); return xl < yl ? -1 : (xl > yl ? 1 : 0) })
                finish(out)
            }

            function maybeFinishRemote() {
                if (_invReady && _manifestReady)
                    collectRemote()
            }

            Component.onCompleted: {
                if (srcType === "file") {
                    resolveFile()
                } else if (srcType === "folder") {
                    // FolderListModel drives; a missing dir resolves to an
                    // empty inventory or is caught by the deadline.
                } else if (isRemote) {
                    // manifest FileView drives; the model below drives.
                } else {
                    finish([])   // unknown type: no clips, never an error
                }
            }

            // One directory inventory per folder/remote source.
            property FolderListModel invModel: FolderListModel {
                showDirs: false
                showHidden: false
                showDotAndDotDot: false
                sortField: FolderListModel.Name
                sortCaseSensitive: false
                nameFilters: del.srcType === "folder" ? root.vidFilters : ["*.mp4", "*.mp4.done"]
                folder: {
                    if (del.srcType === "folder")
                        return "file://" + root.expandHome(del.modelData.source)
                    if (del.isRemote)
                        return "file://" + root.cacheBase + "/" + del.safeName + "/videos"
                    return ""
                }

                onStatusChanged: {
                    if (status !== FolderListModel.Ready)
                        return
                    if (del.srcType === "folder")
                        del.collectFolder()
                    else if (del.isRemote) {
                        del._invReady = true
                        del.maybeFinishRemote()
                    }
                }
            }

            // One fresh nonblocking read of the remote manifest. Loaded
            // and load-failed are both readiness; the deadline bounds the
            // whole inventory regardless.
            property FileView manifest: FileView {
                blockLoading: false
                printErrors: false
                path: del.isRemote ? root.cacheBase + "/" + del.safeName + "/entries.json" : ""

                function parseManifest() {
                    var raw = manifest.text()
                    var parsed = null
                    if (raw && raw.length > 0) {
                        try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
                    }
                    // Never memoize an early absent manifest forever: until
                    // the snapshot is frozen, content changes re-parse.
                    if (!root.resolved || parsed !== null)
                        root._manifests[del.safeName] = parsed
                }

                onLoaded: {
                    parseManifest()
                    del._manifestReady = true
                    del.maybeFinishRemote()
                }
                onTextChanged: {
                    if (!root.resolved)
                        parseManifest()
                }
                onLoadFailed: function (err) {
                    root._manifests[del.safeName] = null
                    del._manifestReady = true
                    del.maybeFinishRemote()
                }
            }
        }
    }

    // d38: resolve a playing path to its source + manifest metadata.
    // Returns null when the path belongs to no configured source. Manifest
    // fields are "" when the source has no entries.json for it. Apple POI
    // stays unresolved (d38 §3); community prose POI works.
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
                var entries = _manifests[src.safeName]
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
}
