import CoreAudio
import Foundation
import IOKit
import VoxKit

/// Reads the audio devices the HAL currently knows about. Every call queries
/// CoreAudio fresh, so a device that connects between dictations is seen on
/// the next one.
public enum AudioDevices {
    public static func all() -> [AudioDeviceInfo] {
        deviceIDs().compactMap(info(for:))
    }

    public static func inputs() -> [AudioDeviceInfo] {
        all().filter(\.hasInput)
    }

    public static var defaultInputUID: String? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice).flatMap(uid(of:))
    }

    public static var defaultOutputUID: String? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice).flatMap(uid(of:))
    }

    /// True while a MacBook's lid is closed. The built-in mic stays listed
    /// then but records silence, so it must not be picked automatically.
    public static var isClamshellClosed: Bool {
        let rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        let value = IORegistryEntryCreateCFProperty(
            rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    public static func snapshot() -> AudioSnapshot {
        AudioSnapshot(
            devices: all(),
            defaultInputUID: defaultInputUID,
            defaultOutputUID: defaultOutputUID,
            builtInMicUsable: !isClamshellClosed
        )
    }

    /// The input the next recording should open, given current hardware.
    public static func choose(for config: RecordingConfig) -> InputDeviceSelection.Choice {
        InputDeviceSelection.choose(config: config, snapshot: snapshot())
    }

    /// The UID a recording with `choice` actually opens: the chosen device,
    /// or the system default input when the choice leaves it alone.
    public static func effectiveInputUID(
        for choice: InputDeviceSelection.Choice, defaultInputUID: String? = defaultInputUID
    ) -> String? {
        choice.uid ?? defaultInputUID
    }

    /// Calls `handler` on the main queue whenever a device connects or
    /// disconnects or the default input or output changes. Keep the returned
    /// observer alive for as long as updates are wanted.
    public static func observeChanges(_ handler: @escaping () -> Void) -> ChangeObserver {
        ChangeObserver(handler: handler)
    }

    public final class ChangeObserver {
        private static let selectors = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
        ]
        private let block: AudioObjectPropertyListenerBlock

        fileprivate init(handler: @escaping () -> Void) {
            block = { _, _ in handler() }
            for selector in Self.selectors {
                var address = AudioDevices.address(selector)
                AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            }
        }

        deinit {
            for selector in Self.selectors {
                var address = AudioDevices.address(selector)
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            }
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        deviceIDs().first { self.uid(of: $0) == uid }
    }

    // MARK: - HAL queries

    fileprivate static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var devices = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
        else { return [] }
        return devices
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = address(selector)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
            device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    private static func info(for device: AudioDeviceID) -> AudioDeviceInfo? {
        guard let uid = uid(of: device) else { return nil }
        return AudioDeviceInfo(
            uid: uid,
            name: string(kAudioObjectPropertyName, of: device) ?? uid,
            transport: transport(of: device),
            hasInput: hasStreams(device, scope: kAudioObjectPropertyScopeInput),
            hasOutput: hasStreams(device, scope: kAudioObjectPropertyScopeOutput),
            subdeviceUIDs: subdeviceUIDs(of: device)
        )
    }

    /// Empty unless `device` is an aggregate (which includes multi-output
    /// devices).
    private static func subdeviceUIDs(of device: AudioDeviceID) -> [String] {
        var address = address(kAudioAggregateDevicePropertyActiveSubDeviceList)
        var size: UInt32 = 0
        guard
            AudioObjectHasProperty(device, &address),
            AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }
        var members = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &members) == noErr else {
            return []
        }
        return members.compactMap(uid(of:))
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        string(kAudioDevicePropertyDeviceUID, of: device)
    }

    private static func string(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID) -> String? {
        var address = address(selector)
        // CoreAudio hands back a +1 CFString here, so it has to come out
        // through Unmanaged: a bare `CFString?` makes Swift pass a pointer
        // to a managed reference and leaves ownership ambiguous.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else {
            return nil
        }
        return value.takeRetainedValue() as String
    }

    private static func transport(of device: AudioDeviceID) -> AudioDeviceInfo.Transport {
        var address = address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else {
            return .other
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return .virtual
        default: return .other
        }
    }

    private static func hasStreams(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }
}
