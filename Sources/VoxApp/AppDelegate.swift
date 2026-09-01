import AppKit
import VoxCore
import VoxKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var hotkeyManager: HotkeyManager?
    private let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(state: state)
        installHotkey()

        // Ask for the microphone at launch rather than mid-dictation, where the
        // prompt would eat the first seconds of speech.
        Task { _ = await AudioCapture.requestPermission() }

        state.onConfigChange = { [weak self] config in
            self?.hotkeyManager?.update(with: config.hotkey)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager?.unregister()
    }

    private func installHotkey() {
        let manager = HotkeyManager(
            onPress: { [weak self] in self?.state.hotkeyPressed() },
            onRelease: { [weak self] in self?.state.hotkeyReleased() }
        )
        manager.update(with: state.config.hotkey)
        hotkeyManager = manager
    }
}
