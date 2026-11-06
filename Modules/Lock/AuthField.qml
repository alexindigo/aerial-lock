import QtQuick
import "../../Services"

// Theme-facing adapter. Editing and synchronization have one implementation,
// shared with the context-free input sinks on other lock surfaces.
AuthEditor {
    required property LockContext context
    input: context.auth.input
    inputBusy: context.auth.inProgress
    responseVisible: context.auth.responseVisible
    maxResponseSize: context.auth.maxResponseSize
    textColor: context.colors.input
    fontPixelSize: context.panel.fontSize
    onSubmitRequested: context.auth.submit()
}
