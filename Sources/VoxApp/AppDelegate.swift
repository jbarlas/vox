import AppKit
import VoxCore
import VoxKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var hotkeyManager: HotkeyManager?
    private let state = AppState()
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(state: state)
        installHotkey()

        // Ask for the microphone at launch rather than mid-dictation, where the
        // prompt would eat the first seconds of speech.
        Task { _ = await AudioCapture.requestPermission() }

        state.onConfigChange = { [weak self] config in
            self?.hotkeyManager?.update(with: config.hotkey)
        }

        // `vox update` stops the app with SIGTERM. Quit through AppKit so
        // applicationWillTerminate still runs; the default action exits at once.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Keep the normal event loop and hotkey release handling alive while
        // recording, transcribing, or delivering output. A new quit request is
        // made after that work finishes; no timeout cancels the dictation.
        state.prepareToTerminate { sender.terminate(nil) } ? .terminateNow : .terminateCancel
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
