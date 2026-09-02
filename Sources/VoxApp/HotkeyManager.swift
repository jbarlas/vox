import AppKit
import Carbon.HIToolbox
import VoxKit

/// Global hotkey via Carbon's `RegisterEventHotKey`.
///
/// Chosen over a `CGEvent` tap because it needs no Accessibility permission and
/// reports key release, which press-and-hold activation depends on.
///
/// One instance per chord. Every instance's handler sees every hotkey event
/// the app registered, so each filters on its own `Role` — without that,
/// pressing the fix-last chord would also start a recording.
final class HotkeyManager {
    /// Which chord an instance owns; doubles as the Carbon hotkey ID.
    enum Role: UInt32 {
        case record = 1
        case fixLast = 2
    }

    private let role: Role
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private static let signature = OSType(0x564F_5820)  // 'VOX '

    init(role: Role = .record, onPress: @escaping () -> Void, onRelease: @escaping () -> Void = {}) {
        self.role = role
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
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == HotkeyManager.signature,
                    hotKeyID.id == manager.role.rawValue
                else { return OSStatus(eventNotHandledErr) }
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

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: role.rawValue)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("Vox: could not register the \(role) hotkey (status \(status)); it may be taken by another app.")
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

    /// Labels the standard ANSI/US layout; the recorder itself is
    /// layout-independent (it stores the physical `keyCode` Carbon uses), so
    /// a non-US keyboard would still register correctly, just with a label
    /// that may not match the printed key.
    static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Escape: return "Esc"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Fwd Delete"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Grave: return "`"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        default: return "Key \(keyCode)"
        }
    }

    /// `nil` if `flags` carries no modifier Carbon can register (a bare key
    /// would be rejected as unusable — see `HotkeyConfig.supportedModifiers`).
    static func modifierNames(_ flags: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.command) { names.append("command") }
        return names
    }
}
