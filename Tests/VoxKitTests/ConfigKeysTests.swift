import XCTest

@testable import VoxKit

final class ConfigKeysTests: XCTestCase {
    func testEveryKeyIsReadableFromADefaultConfig() throws {
        let config = VoxConfig()
        for key in ConfigKeys.all {
            XCTAssertNoThrow(try ConfigKeys.get(key, from: config), "reading \(key)")
        }
    }

    func testUnknownKeysAreRejectedBothWays() {
        var config = VoxConfig()
        XCTAssertThrowsError(try ConfigKeys.get("nope", from: config))
        XCTAssertThrowsError(try ConfigKeys.set("nope", to: "1", in: &config))
    }

    func testGetOutputCanBeFedBackIntoSet() throws {
        var config = VoxConfig()
        config.language = nil
        config.recording.silenceTimeoutSeconds = nil
        config.llm.apiKeyEnvVar = nil
        config.llm.maxOutputTokens = nil
        config.recording.inputDeviceUID = nil

        // The words `get` prints for absent values must round-trip through
        // `set` without changing meaning.
        for key in ConfigKeys.all {
            let value = try ConfigKeys.get(key, from: config)
            var copy = config
            try ConfigKeys.set(key, to: value, in: &copy)
            XCTAssertEqual(try ConfigKeys.get(key, from: copy), value, "round-tripping \(key)")
        }
    }

    func testVocabIsSplitNormalizedAndDeduplicated() throws {
        var config = VoxConfig()
        try ConfigKeys.set("vocab", to: " GGUF, litellm ,GGUF, ", in: &config)
        XCTAssertEqual(config.vocabulary, ["GGUF", "litellm"])
    }

    func testModifiersAcceptPlusAndCommaAndRejectUnknown() throws {
        var config = VoxConfig()
        try ConfigKeys.set("hotkey.modifiers", to: "Command+Shift", in: &config)
        XCTAssertEqual(config.hotkey.modifiers, ["command", "shift"])
        try ConfigKeys.set("hotkey.modifiers", to: "option, control", in: &config)
        XCTAssertEqual(config.hotkey.modifiers, ["option", "control"])
        XCTAssertThrowsError(try ConfigKeys.set("hotkey.modifiers", to: "hyper", in: &config))
    }

    func testBooleanSynonyms() throws {
        var config = VoxConfig()
        for truthy in ["true", "yes", "on", "1"] {
            try ConfigKeys.set("hotkey.enabled", to: truthy, in: &config)
            XCTAssertTrue(config.hotkey.enabled)
        }
        for falsy in ["false", "no", "0"] {
            try ConfigKeys.set("hotkey.enabled", to: falsy, in: &config)
            XCTAssertFalse(config.hotkey.enabled)
        }
    }

    func testUnsetWordsClearOptionalFields() throws {
        var config = VoxConfig()
        try ConfigKeys.set("language", to: "auto", in: &config)
        XCTAssertNil(config.language)
        try ConfigKeys.set("recording.silence_timeout_seconds", to: "off", in: &config)
        XCTAssertNil(config.recording.silenceTimeoutSeconds)
        try ConfigKeys.set("llm.max_output_tokens", to: "unset", in: &config)
        XCTAssertNil(config.llm.maxOutputTokens)
    }

    func testInvalidValuesAreRejectedAndLeaveConfigValid() {
        var config = VoxConfig()
        XCTAssertThrowsError(try ConfigKeys.set("model", to: "nope", in: &config))
        XCTAssertThrowsError(try ConfigKeys.set("output.destination", to: "fax", in: &config))
        XCTAssertThrowsError(try ConfigKeys.set("hotkey.activation", to: "hold", in: &config))
        XCTAssertThrowsError(try ConfigKeys.set("recording.max_duration_seconds", to: "0", in: &config))
        XCTAssertThrowsError(try ConfigKeys.set("recording.silence_threshold_db", to: "12", in: &config))
        XCTAssertThrowsError(try ConfigKeys.set("hotkey.key_code", to: "999", in: &config))
        XCTAssertThrowsError(try ConfigKeys.set("llm.temperature", to: "warm", in: &config))
    }

    func testMaxOutputTokensAcceptsValuesAboveUInt16() throws {
        var config = VoxConfig()
        try ConfigKeys.set("llm.max_output_tokens", to: "100000", in: &config)
        XCTAssertEqual(config.llm.maxOutputTokens, 100_000)
    }
}
