import ArgumentParser
import Foundation
import VoxCore
import VoxKit

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List audio input devices and which one the next recording will use.",
        discussion: """
            `*` marks the device the next recording is expected to open, given \
            the hardware right now. Selection runs again when recording starts, \
            so a device change in between can change it. Pin one with \
            `vox config set recording.input_device_uid <uid>`.
            """
    )

    @OptionGroup var configOptions: ConfigOptions

    @Flag(help: "Print JSON instead of a table.")
    var json = false

    struct Listing: Encodable {
        let devices: [AudioDeviceInfo]
        let defaultInputUid: String?
        let defaultOutputUid: String?
        let selectedUid: String?
        let selectionReason: InputDeviceSelection.Reason
    }

    func run() throws {
        // Same loading as `vox record`, so a broken config fails here too
        // rather than listing a selection the recorder would never make.
        let recording: RecordingConfig
        do {
            recording = try configOptions.loadConfig().recording
        } catch {
            voxError(from: error).printToStderr()
            throw voxExitCode(for: error)
        }
        let snapshot = AudioDevices.snapshot()
        let inputs = snapshot.devices.filter(\.hasInput)
        let defaultInput = snapshot.defaultInputUID
        let choice = InputDeviceSelection.choose(config: recording, snapshot: snapshot)
        let selected = AudioDevices.effectiveInputUID(for: choice, defaultInputUID: defaultInput)

        if json {
            Stdout.write(try VoxJSON.string(Listing(
                devices: inputs,
                defaultInputUid: defaultInput,
                defaultOutputUid: snapshot.defaultOutputUID,
                selectedUid: selected,
                selectionReason: choice.reason
            ), pretty: true))
            return
        }
        for device in inputs {
            let marker = device.uid == selected ? "*" : " "
            let name = device.name.padding(toLength: 28, withPad: " ", startingAt: 0)
            let transport = device.transport.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            let note = device.uid == defaultInput ? "  (system default)" : ""
            Stdout.write("\(marker) \(name) \(transport) \(device.uid)\(note)")
        }
        if choice.reason == .builtInOverBluetooth {
            Stderr.write(
                "Using the built-in mic so Bluetooth playback is not interrupted. "
                    + "Turn this off with `vox config set recording.prefer_built_in_mic false`."
            )
        }
        if let configured = recording.inputDeviceUID, !inputs.contains(where: { $0.uid == configured }) {
            Stderr.write("Configured input '\(configured)' is not connected; recording will fail until it is.")
        }
    }
}
