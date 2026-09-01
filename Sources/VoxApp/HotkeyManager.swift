import AppKit
import Carbon.HIToolbox
import VoxKit

/// Global hotkey via Carbon's `RegisterEventHotKey`.
///
/// Chosen over a `CGEvent` tap because it needs no Accessibility permission and
/// reports key release, which press-and-hold activation depends on.
final class HotkeyManager {
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private static let signature = OSType(0x564F_5820)  // 'VOX '
    private static let identifier: UInt32 = 1

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    deinit {
        unregister()
    }

    func update(with config: HotkeyConfig) {
        unregister()
        guard config.enabled else { return }
        register(keyCode: config.keyCode, modifiers: Self.carbonModifiers(config.modifiers))
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func register(keyCode: UInt16, modifiers: UInt32) {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                let kind = GetEventKind(event)
                // Carbon delivers on the main thread, but the handlers touch
                // @MainActor state, so hop explicitly.
                DispatchQueue.main.async {
                    if kind == UInt32(kEventHotKeyPressed) {
                        manager.onPress()
                    } else {
                        manager.onRelease()
                    }
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            context,
            &eventHandler
        )

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("Vox: could not register the global hotkey (status \(status)); it may be taken by another app.")
        }
    }

    static func carbonModifiers(_ names: [String]) -> UInt32 {
        var mask: UInt32 = 0
        for name in names {
            switch name.lowercased() {
            case "command": mask |= UInt32(cmdKey)
            case "option": mask |= UInt32(optionKey)
            case "control": mask |= UInt32(controlKey)
            case "shift": mask |= UInt32(shiftKey)
            default: break
            }
        }
        return mask
    }

    /// Human-readable chord for the settings UI, e.g. "⌥Space".
    static func displayString(_ config: HotkeyConfig) -> String {
        var result = ""
        if config.modifiers.contains("control") { result += "⌃" }
        if config.modifiers.contains("option") { result += "⌥" }
        if config.modifiers.contains("shift") { result += "⇧" }
        if config.modifiers.contains("command") { result += "⌘" }
        return result + keyName(for: config.keyCode)
    }

    static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Escape: return "Esc"
        case kVK_Tab: return "Tab"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_V: return "V"
        default: return "Key \(keyCode)"
        }
    }
}
