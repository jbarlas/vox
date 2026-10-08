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

    public init(uid: String, name: String, transport: Transport, hasInput: Bool, hasOutput: Bool) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.hasInput = hasInput
        self.hasOutput = hasOutput
    }
}

/// Decides which microphone a recording opens.
///
/// Opening a Bluetooth headset's mic switches it from its playback profile
/// (A2DP) to the headset profile (HFP): whatever is playing drops out for about
/// a second, comes back as low quality mono, and drops out again when the mic
/// closes. So when no device is configured and the system default input is a
/// Bluetooth mic while audio is also playing through Bluetooth, the built-in
/// mic is used instead.
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

    /// - Parameter builtInMicUsable: false when the built-in mic is present but
    ///   unusable, e.g. a MacBook with its lid closed, which records silence.
    public static func choose(
        config: RecordingConfig,
        devices: [AudioDeviceInfo],
        defaultInputUID: String?,
        defaultOutputUID: String?,
        builtInMicUsable: Bool
    ) -> Choice {
        if let uid = config.inputDeviceUID {
            return Choice(uid: uid, reason: .configured)
        }
        let systemDefault = Choice(uid: nil, reason: .systemDefault)
        guard config.preferBuiltInMicOverBluetooth, builtInMicUsable else { return systemDefault }

        func device(_ uid: String?) -> AudioDeviceInfo? {
            uid.flatMap { uid in devices.first { $0.uid == uid } }
        }
        guard
            device(defaultInputUID)?.transport == .bluetooth,
            device(defaultOutputUID)?.transport == .bluetooth,
            let builtIn = devices.first(where: { $0.transport == .builtIn && $0.hasInput })
        else { return systemDefault }
        return Choice(uid: builtIn.uid, reason: .builtInOverBluetooth)
    }
}
