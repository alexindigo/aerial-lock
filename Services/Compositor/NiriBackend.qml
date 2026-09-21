import QtQuick
import Niri

Item {
    readonly property string backendName: "niri"
    readonly property bool available: NiriConnection.isConnected
    readonly property string focusedOutputName: available ? (NiriState.activeOutput || "") : ""
}
