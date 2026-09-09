import Cocoa

// AppKit programmatic entry point (no storyboard).
// Runs on the main thread; AppKit requires main-actor isolation.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu-bar resident app
    app.run()
}
