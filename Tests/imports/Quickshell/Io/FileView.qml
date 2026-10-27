import QtQml

// Only the inactive probes are instantiated. Any accidental I/O fails loudly.
QtObject {
    property string path: ""
    property bool blockLoading: false
    property bool printErrors: false
    property bool atomicWrites: false
    signal loaded()
    signal loadFailed(int error)
    signal saveFailed(int err)
    onPathChanged: { throw new Error("File probing is outside the handoff test") }
    function text() { throw new Error("Unexpected FileView read") }
    function setText(value) { throw new Error("Unexpected FileView write") }
    function waitForJob() { throw new Error("Unexpected FileView wait") }
}
