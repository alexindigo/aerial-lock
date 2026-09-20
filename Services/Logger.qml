pragma Singleton
import QtQuick

QtObject {
    id: root

    // Set once from shell.qml: the d19 verbose build flag, or
    // AERIAL_LOCK_VERBOSE=1. Debug chatter is suppressed unless true;
    // warnings always print.
    property bool verbose: false

    function d(tag, msg) {
        if (verbose)
            console.log("[" + Date.now() + "] " + tag + ": " + msg)
    }

    function w(tag, msg) {
        console.warn(tag + ": " + msg)
    }
}
