import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import VoxKit

/// Delivers a finished transcript to wherever the caller wants it.
///
/// The `json` destination is the agent-facing one and is deliberately the only
/// destination that requires no permissions and no GUI.
public struct OutputRouter {
    private let history: SessionHistory?

    public init(history: SessionHistory? = nil) {
        self.history = history
    }

    @discardableResult
    public func deliver(
        result: RecordResult,
        destination: OutputConfig.Destination,
        pretty: Bool = false
    ) throws -> String? {
        if let history {
            // Best-effort: losing the session log must never fail a dictation.
            try? history.append(SessionEntry(result: result))
        }

        switch destination {
        case .clipboard:
            try copyToClipboard(result.transcript)
            return nil
        case .autoPaste:
            try copyToClipboard(result.transcript)
            try OutputRouter.paste()
            return nil
        case .stdout:
            return result.transcript
        case .json:
            return try VoxJSON.string(RecordEnvelope(result: result), pretty: pretty)
        case .none:
            return nil
        }
    }

    public func copyToClipboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw VoxError(code: .output, message: "Could not write the transcript to the clipboard")
        }
    }

    /// True when the process may post synthetic events. Auto-paste is the only
    /// feature that needs this, so it is checked lazily rather than at launch.
    public static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Sends Command-V to the frontmost app.
    ///
    /// Typing the transcript as synthetic unicode events was the alternative;
    /// Command-V is used instead because it is atomic (no per-character races
    /// with autocomplete) and every text surface honours it.
    public static func paste() throws {
        guard hasAccessibilityPermission else {
            throw VoxError(
                code: .permission,
                message: "Auto-paste needs Accessibility permission",
                detail: "Grant it in System Settings → Privacy & Security → Accessibility, then try again."
            )
        }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw VoxError(code: .output, message: "Could not create an event source for auto-paste")
        }
        // 9 is the virtual key code for "v".
        let keyCode: CGKeyCode = 9
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            throw VoxError(code: .output, message: "Could not synthesize the paste keystroke")
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Opens the Accessibility pane with the prompt macOS shows on first use.
    public static func promptForAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}
