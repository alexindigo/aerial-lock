import QtQuick
import Quickshell

Scope {
    id: root

    readonly property string backendName: {
        var niri = Quickshell.env("NIRI_SOCKET")
        if (niri && niri.length > 0)
            return "niri"
        var hypr = Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")
        if (hypr && hypr.length > 0)
            return "hyprland"
        return "none"
    }

    readonly property bool backendReady: backendName === "none"
            || backendLoader.status === Loader.Ready
            || backendLoader.status === Loader.Error

    readonly property string focusedOutputName: nameFrom(backendLoader.item)

    function nameFrom(item) {
        if (backendLoader.status !== Loader.Ready || !item)
            return ""
        if (!item.available)
            return ""
        return item.focusedOutputName ? item.focusedOutputName : ""
    }

    Loader {
        id: backendLoader
        source: {
            if (root.backendName === "niri")
                return "Compositor/NiriBackend.qml"
            if (root.backendName === "hyprland")
                return "Compositor/HyprlandBackend.qml"
            return ""
        }
        onStatusChanged: {
            if (status === Loader.Error)
                Logger.w("Compositor", "failed to load " + source
                         + " — using portable defaults")
        }
    }
}
