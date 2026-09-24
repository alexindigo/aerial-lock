import QtQuick
import Quickshell
import Quickshell.Io

// Apple Aerial cache sentinel (d35). The fetch script owns the network;
// this only observes the on-disk cache. videosDir is the cache's videos/
// path when the sentinel manifest exists and apple playback is enabled,
// else "". The locker treats a missing or empty cache as a no-op.
Scope {
    id: root

    required property ConfigStore config

    property string videosDir: ""

    readonly property string cacheDir: {
        var xdg = Quickshell.env("XDG_CACHE_HOME")
        if (xdg && xdg.length > 0) return xdg + "/aerial-lock/apple"
        var home = Quickshell.env("HOME")
        return home ? home + "/.cache/aerial-lock/apple" : ""
    }

    function refresh() {
        var enabled = !!(config.data.apple && config.data.apple.enabled)
        var hasManifest = sentinel.text().length > 0
        videosDir = (enabled && hasManifest) ? cacheDir + "/videos" : ""
    }

    FileView {
        id: sentinel
        path: root.cacheDir + "/entries.json"
        blockLoading: true
        printErrors: false     // a missing cache is a normal state, not an error

        onTextChanged: root.refresh()
        onLoadFailed: root.refresh()
    }

    Component.onCompleted: {
        // Same contract as ConfigStore: false means no load job was queued
        // (structural), otherwise the blocked read above is definitive —
        // empty text is a genuinely absent/unreadable manifest.
        if (!sentinel.waitForJob()) {
            Logger.w("AppleCache", "no load job was queued for " + sentinel.path)
        }
        refresh()
    }
}
