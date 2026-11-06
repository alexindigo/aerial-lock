import QtQuick

// Invisible but focusable. It owns no response state or consumer knowledge.
// Opacity, rather than visibility, keeps Qt's native editor eligible for focus.
AuthEditor {
    themeEditor: false
    width: 1
    height: 1
    opacity: 0
}
