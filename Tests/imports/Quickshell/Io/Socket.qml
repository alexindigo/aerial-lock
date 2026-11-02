import QtQuick

// Inactive transport boundary only. Production framing is exercised with the
// real Socket/SplitParser in the nested-compositor release integration.
Item {
    property string path: ""
    property bool connected: false
    property QtObject parser: null
    function write(data) { throw new Error("Socket writes require the guest integration") }
    function flush() { throw new Error("Socket flush requires the guest integration") }
}
