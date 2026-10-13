import AppKit
import Combine
import SwiftUI
import VoxKit

/// Owns the menu bar icon, the popover, and the settings window.
@MainActor
final class StatusItemController: NSObject {
    private let state: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let popoverContent: NSHostingController<PopoverView>
    private var settingsWindow: NSWindow?
    private var cancellables = Swift.Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popoverContent = NSHostingController(
            rootView: PopoverView(state: state, openSettings: {})
        )
        super.init()
        // PopoverView's height genuinely varies (the level meter and "Last
        // transcript" sections come and go), but the popover was given one
        // fixed contentSize at construction time and never updated — on any
        // state where the real content differs from that guess, NSPopover's
        // anchor/arrow math goes stale and the popover can appear detached,
        // floating well below the status item instead of right under it.
        // sizingOptions keeps NSPopover in sync with the actual SwiftUI
        // content size automatically; recomputing it in togglePopover()
        // below covers macOS versions before that option existed (13.3).
        if #available(macOS 13.3, *) {
            popoverContent.sizingOptions = .preferredContentSize
        }
        popoverContent.rootView = PopoverView(state: state, openSettings: { [weak self] in self?.openSettings() })
        popover.behavior = .transient
        popover.contentViewController = popoverContent

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        state.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.updateIcon(for: status) }
            .store(in: &cancellables)
        updateIcon(for: state.status)
    }

    @objc private func togglePopover() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            state.toggleDictation()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            // Belt-and-suspenders alongside sizingOptions above: fits the
            // popover to the content it's about to show, for the very first
            // show() (before sizingOptions has anything to react to) and on
            // macOS < 13.3, where sizingOptions doesn't exist at all.
            let fitting = popoverContent.view.fittingSize
            popover.contentSize = NSSize(width: 320, height: max(fitting.height, 1))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// SF Symbols carry the three states; no custom artwork needed and it
    /// follows the menu bar's light/dark appearance automatically.
    private func updateIcon(for status: AppState.Status) {
        guard let button = statusItem.button else { return }
        let symbol: String
        let description: String
        switch status {
        case .idle:
            symbol = "mic"
            description = "Vox — idle"
        case .recording:
            symbol = "mic.fill"
            description = "Vox — recording"
        case .processing:
            symbol = "waveform"
            description = "Vox — transcribing"
        case .failed:
            symbol = "exclamationmark.triangle"
            description = "Vox — error"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.image?.isTemplate = true
        button.toolTip = description
    }

    func openSettings() {
        popover.performClose(nil)
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vox Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(state: state))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}
