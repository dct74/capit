import Cocoa

/// The app's modal alerts. They differ only in text, style and buttons — the activate-then-runModal
/// dance was copied into four call sites.
@MainActor
@discardableResult
func presentAlert(_ title: String, _ message: String,
                  style: NSAlert.Style = .warning,
                  buttons: [String] = ["好"]) -> NSApplication.ModalResponse {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = style
    for b in buttons { alert.addButton(withTitle: b) }
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal()
}

