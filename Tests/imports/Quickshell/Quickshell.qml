pragma Singleton
import QtQml

QtObject {
    readonly property string shellDir: ""
    function env(name) {
        throw new Error("Quickshell environment access is outside the handoff test")
    }
}
