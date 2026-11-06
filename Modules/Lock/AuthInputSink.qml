import QtQuick

// Invisible but focusable. It owns no response state or consumer knowledge.
// Opacity, rather than visibility, keeps Qt's native editor eligible for focus.
AuthEditor {
    // Panel arrival changes presentation immediately, but must not disable
    // the current native focus object while its composition is still live.
    property bool panelAttached: false
    visible: !panelAttached || _active
    enabled: visible
    themeEditor: false
    width: 1
    height: 1
    opacity: 0
}
