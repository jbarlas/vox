import AppKit

// Menu bar only: `.accessory` keeps Vox out of the Dock and the app switcher.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
