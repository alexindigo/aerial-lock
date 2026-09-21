import QtQuick
import Quickshell.Hyprland

Item {
    readonly property string backendName: "hyprland"
    readonly property bool available: Hyprland.focusedMonitor !== null
    readonly property string focusedOutputName: Hyprland.focusedMonitor
            ? Hyprland.focusedMonitor.name : ""
}
