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
    private var settingsWindow: NSWindow?
    private var cancellables = Swift.Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 260)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(state: state, openSettings: { [weak self] in self?.openSettings() })
        )

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
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
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
