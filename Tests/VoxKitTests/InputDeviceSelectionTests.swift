import XCTest

@testable import VoxKit

final class InputDeviceSelectionTests: XCTestCase {
    private let airpodsIn = AudioDeviceInfo(
        uid: "AA:input", name: "AirPods", transport: .bluetooth, hasInput: true, hasOutput: false)
    private let airpodsOut = AudioDeviceInfo(
        uid: "AA:output", name: "AirPods", transport: .bluetooth, hasInput: false, hasOutput: true)
    private let builtInMic = AudioDeviceInfo(
        uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn,
        hasInput: true, hasOutput: false)
    private let speakers = AudioDeviceInfo(
        uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", transport: .builtIn,
        hasInput: false, hasOutput: true)
    private let usbMic = AudioDeviceInfo(
        uid: "USB-1", name: "Yeti", transport: .usb, hasInput: true, hasOutput: false)

    private var allDevices: [AudioDeviceInfo] { [airpodsIn, airpodsOut, builtInMic, speakers, usbMic] }

    private func choose(
        config: RecordingConfig = RecordingConfig(),
        devices: [AudioDeviceInfo]? = nil,
        input: String?,
        output: String?,
        builtInMicUsable: Bool = true
    ) -> InputDeviceSelection.Choice {
        InputDeviceSelection.choose(
            config: config,
            devices: devices ?? allDevices,
            defaultInputUID: input,
            defaultOutputUID: output,
            builtInMicUsable: builtInMicUsable
        )
    }

    func testBluetoothInAndOutPrefersBuiltInMic() {
        let choice = choose(input: airpodsIn.uid, output: airpodsOut.uid)
        XCTAssertEqual(choice, .init(uid: builtInMic.uid, reason: .builtInOverBluetooth))
    }

    func testBluetoothInputWithSpeakerOutputKeepsDefault() {
        // Nothing is playing through the headset, so its mic costs nothing.
        let choice = choose(input: airpodsIn.uid, output: speakers.uid)
        XCTAssertEqual(choice, .init(uid: nil, reason: .systemDefault))
    }

    func testNonBluetoothDefaultInputIsKept() {
        XCTAssertEqual(choose(input: usbMic.uid, output: airpodsOut.uid).reason, .systemDefault)
        XCTAssertEqual(choose(input: builtInMic.uid, output: airpodsOut.uid).reason, .systemDefault)
    }

    func testConfiguredDeviceAlwaysWins() {
        let config = RecordingConfig(inputDeviceUID: airpodsIn.uid)
        let choice = choose(config: config, input: airpodsIn.uid, output: airpodsOut.uid)
        XCTAssertEqual(choice, .init(uid: airpodsIn.uid, reason: .configured))
    }

    func testConfiguredDeviceWinsEvenWhenDisconnected() {
        // AudioCapture turns this into a clear error rather than silently
        // recording from something else.
        let config = RecordingConfig(inputDeviceUID: "gone")
        XCTAssertEqual(choose(config: config, input: nil, output: nil).uid, "gone")
    }

    func testPreferenceOffKeepsDefault() {
        let config = RecordingConfig(preferBuiltInMic: false)
        let choice = choose(config: config, input: airpodsIn.uid, output: airpodsOut.uid)
        XCTAssertEqual(choice.reason, .systemDefault)
    }

    func testClosedLidKeepsDefault() {
        let choice = choose(input: airpodsIn.uid, output: airpodsOut.uid, builtInMicUsable: false)
        XCTAssertEqual(choice.reason, .systemDefault)
    }

    func testNoBuiltInMicKeepsDefault() {
        // A desktop Mac without a microphone.
        let choice = choose(
            devices: [airpodsIn, airpodsOut, speakers, usbMic],
            input: airpodsIn.uid, output: airpodsOut.uid)
        XCTAssertEqual(choice.reason, .systemDefault)
    }

    func testBuiltInOutputOnlyDeviceIsNotPickedAsMic() {
        let choice = choose(
            devices: [airpodsIn, airpodsOut, speakers],
            input: airpodsIn.uid, output: airpodsOut.uid)
        XCTAssertNil(choice.uid)
    }

    func testUnknownDefaultsKeepDefault() {
        XCTAssertEqual(choose(input: nil, output: nil).reason, .systemDefault)
        XCTAssertEqual(choose(input: "missing", output: airpodsOut.uid).reason, .systemDefault)
    }

    func testPreferenceDefaultsToOnAndIsOptionalInConfigFiles() throws {
        let json = #"{"max_duration_seconds": 60, "silence_threshold_db": -45}"#
        let decoded = try VoxJSON.decoder().decode(RecordingConfig.self, from: Data(json.utf8))
        XCTAssertNil(decoded.preferBuiltInMic)
        XCTAssertTrue(decoded.preferBuiltInMicOverBluetooth)
    }

    func testPreferenceRoundTripsThroughJSON() throws {
        let config = RecordingConfig(preferBuiltInMic: false)
        let text = try VoxJSON.string(config)
        XCTAssertTrue(text.contains(#""prefer_built_in_mic":false"#), text)
        let decoded = try VoxJSON.decoder().decode(RecordingConfig.self, from: Data(text.utf8))
        XCTAssertEqual(decoded, config)
    }

    func testConfigKeySetsAndGetsPreference() throws {
        var config = VoxConfig()
        XCTAssertEqual(try ConfigKeys.get("recording.prefer_built_in_mic", from: config), "true")
        try ConfigKeys.set("recording.prefer_built_in_mic", to: "false", in: &config)
        XCTAssertEqual(config.recording.preferBuiltInMic, false)
        XCTAssertThrowsError(try ConfigKeys.set("recording.prefer_built_in_mic", to: "maybe", in: &config))
    }
}
