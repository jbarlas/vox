import AppKit

// main.swift's top-level code isn't @MainActor-isolated by default under
// strict concurrency, even though process launch always runs it on the main
// thread; assumeIsolated asserts that known fact instead of working around
// it.
MainActor.assumeIsolated {
    // Menu bar only: `.accessory` keeps Vox out of the Dock and the app switcher.
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
