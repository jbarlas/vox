import Foundation

/// One CoreAudio device as far as microphone selection cares. Built by
/// `VoxCore.AudioDevices` from the HAL; kept here so the selection rule is
/// testable without a Mac.
public struct AudioDeviceInfo: Codable, Sendable, Equatable {
    public enum Transport: String, Codable, Sendable {
        case builtIn
        case bluetooth
        case usb
        case virtual
        case other
    }

    public let uid: String
    public let name: String
    public let transport: Transport
    public let hasInput: Bool
    public let hasOutput: Bool
    /// Member device UIDs of an aggregate or multi-output device; empty
    /// otherwise.
    public let subdeviceUIDs: [String]

    public init(
        uid: String,
        name: String,
        transport: Transport,
        hasInput: Bool,
        hasOutput: Bool,
        subdeviceUIDs: [String] = []
    ) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.hasInput = hasInput
        self.hasOutput = hasOutput
        self.subdeviceUIDs = subdeviceUIDs
    }

    /// Identifies the physical device. CoreAudio lists a Bluetooth headset as
    /// two devices, `<address>:input` and `<address>:output`.
    var hardwareKey: String {
        for suffix in [":input", ":output"] where uid.hasSuffix(suffix) {
            return String(uid.dropLast(suffix.count))
        }
        return uid
    }
}

/// The hardware state a selection is made against.
public struct AudioSnapshot: Sendable, Equatable {
    public let devices: [AudioDeviceInfo]
    public let defaultInputUID: String?
    public let defaultOutputUID: String?
    /// False when the built-in mic is present but unusable, e.g. a MacBook
    /// with its lid closed, which records silence.
    public let builtInMicUsable: Bool

    public init(
        devices: [AudioDeviceInfo],
        defaultInputUID: String?,
        defaultOutputUID: String?,
        builtInMicUsable: Bool
    ) {
        self.devices = devices
        self.defaultInputUID = defaultInputUID
        self.defaultOutputUID = defaultOutputUID
        self.builtInMicUsable = builtInMicUsable
    }

    public func device(_ uid: String?) -> AudioDeviceInfo? {
        uid.flatMap { uid in devices.first { $0.uid == uid } }
    }
}

/// Decides which microphone a recording opens.
///
/// Opening a Bluetooth headset's mic switches it from its playback profile
/// (A2DP) to the headset profile (HFP): whatever is playing drops out for about
/// a second, comes back as low quality mono, and drops out again when the mic
/// closes. So when no device is configured and the system default input is a
/// Bluetooth headset that is also the default output, the built-in mic is used
/// instead.
public enum InputDeviceSelection {
    public enum Reason: String, Codable, Sendable {
        /// `recording.input_device_uid` names a device.
        case configured
        /// The system default input, used as is.
        case systemDefault
        /// The built-in mic, used in place of a Bluetooth default input.
        case builtInOverBluetooth
    }

    public struct Choice: Sendable, Equatable {
        /// `nil` leaves the input node on the system default.
        public let uid: String?
        public let reason: Reason
    }

    /// `snapshot` is only evaluated when the config leaves the choice to the
    /// hardware, so a pinned device or a disabled preference costs no HAL
    /// queries.
    public static func choose(
        config: RecordingConfig,
        snapshot: @autoclosure () -> AudioSnapshot
    ) -> Choice {
        if let uid = config.inputDeviceUID {
            return Choice(uid: uid, reason: .configured)
        }
        let systemDefault = Choice(uid: nil, reason: .systemDefault)
        guard config.preferBuiltInMicOverBluetooth else { return systemDefault }
        let snapshot = snapshot()
        guard
            snapshot.builtInMicUsable,
            let input = snapshot.device(snapshot.defaultInputUID),
            input.transport == .bluetooth,
            playsThrough(input, snapshot: snapshot),
            let builtIn = snapshot.devices.first(where: { $0.transport == .builtIn && $0.hasInput })
        else { return systemDefault }
        return Choice(uid: builtIn.uid, reason: .builtInOverBluetooth)
    }

    /// Whether the default output plays through the same headset as `input`,
    /// directly or as a member of a multi-output device. A headset mic used
    /// alongside a different Bluetooth speaker interrupts nothing.
    private static func playsThrough(_ input: AudioDeviceInfo, snapshot: AudioSnapshot) -> Bool {
        guard let output = snapshot.device(snapshot.defaultOutputUID) else { return false }
        let outputs = [output] + output.subdeviceUIDs.compactMap(snapshot.device)
        return outputs.contains { $0.transport == .bluetooth && $0.hardwareKey == input.hardwareKey }
    }
}
