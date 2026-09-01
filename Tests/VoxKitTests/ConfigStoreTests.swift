import XCTest

@testable import VoxKit

final class ConfigStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ConfigStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vox-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ConfigStore(paths: VoxPaths(supportDirectory: directory))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLoadWithoutFileReturnsDefaults() throws {
        let config = try store.load()
        XCTAssertEqual(config.model, ModelCatalog.defaultModelID)
        XCTAssertEqual(config.defaultMode, "raw")
        XCTAssertEqual(config.modes.map(\.name), ["raw", "cleanup", "prompt", "email"])
    }

    func testInitializeIsIdempotentUnlessForced() throws {
        XCTAssertTrue(try store.initializeIfNeeded())
        XCTAssertFalse(try store.initializeIfNeeded())
        XCTAssertTrue(try store.initializeIfNeeded(force: true))
    }

    func testInitializeRejectsUnknownModel() {
        XCTAssertThrowsError(try store.initializeIfNeeded(model: "not-a-model")) { error in
            XCTAssertEqual((error as? VoxError)?.code, .config)
        }
    }

    func testRoundTripPreservesEveryField() throws {
        var config = VoxConfig()
        config.model = "tiny.en"
        config.language = nil
        config.vocabulary = ["LiteLLM", "GGUF"]
        config.hotkey = HotkeyConfig(keyCode: 4, modifiers: ["command", "shift"], activation: .toggle)
        config.recording.silenceTimeoutSeconds = nil
        config.output.destination = .json
        config.feedback = FeedbackConfig(
            soundsEnabled: false,
            startSound: "Hero",
            stopSound: nil,
            errorSound: "Funk",
            showOverlay: false
        )
        config.llm.maxOutputTokens = nil
        config.modes.append(
            ModeDefinition(name: "terse", kind: .llm, prompt: "Be terse.", model: "ollama/qwen2.5")
        )
        try store.save(config)

        XCTAssertEqual(try store.load(), config)
    }

    func testConfigFileUsesSnakeCaseKeys() throws {
        try store.save(VoxConfig())
        let json = try XCTUnwrap(String(data: try Data(contentsOf: store.paths.configFile), encoding: .utf8))
        XCTAssertTrue(json.contains("\"default_mode\""))
        XCTAssertTrue(json.contains("\"schema_version\""))
        XCTAssertFalse(json.contains("\"defaultMode\""))
        // Acronyms are the easy ones to get wrong; see RecordingConfig.CodingKeys.
        XCTAssertTrue(json.contains("\"silence_threshold_db\""))
        XCTAssertTrue(json.contains("\"base_url\""))
    }

    func testCorruptConfigReportsConfigError() throws {
        try Data("{ not json".utf8).write(to: store.paths.configFile)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual((error as? VoxError)?.code, .config)
        }
    }

    func testFutureSchemaVersionIsRejected() throws {
        var config = VoxConfig()
        config.schemaVersion = VoxConfig.currentSchemaVersion + 1
        // Written directly: `save` validates and would refuse it.
        try VoxJSON.encoder().encode(config).write(to: store.paths.configFile)
        XCTAssertThrowsError(try store.load())
    }

    func testValidateRejectsUnknownDefaultModeAndDuplicates() {
        var config = VoxConfig()
        config.defaultMode = "nope"
        XCTAssertThrowsError(try config.validate())

        var duplicated = VoxConfig()
        duplicated.modes.append(ModeDefinition(name: "RAW", kind: .raw))
        XCTAssertThrowsError(try duplicated.validate())
    }

    func testLLMModeWithoutPromptIsRejected() {
        var config = VoxConfig()
        config.modes.append(ModeDefinition(name: "broken", kind: .llm, prompt: "  "))
        XCTAssertThrowsError(try config.validate())
    }

    func testUpdateAppliesMutationAndPersists() throws {
        try store.save(VoxConfig())
        let updated = try store.update { config in
            try ConfigKeys.set("model", to: "base.en", in: &config)
        }
        XCTAssertEqual(updated.model, "base.en")
        XCTAssertEqual(try store.load().model, "base.en")
    }

    /// A config written before a section existed must keep loading; only the
    /// schema version gates compatibility.
    func testConfigMissingASectionFallsBackToDefaults() throws {
        let json = """
        {"schema_version": 1, "model": "tiny.en", "default_mode": "raw"}
        """
        try Data(json.utf8).write(to: store.paths.configFile)
        let config = try store.load()
        XCTAssertEqual(config.model, "tiny.en")
        XCTAssertEqual(config.feedback, .default)
        XCTAssertEqual(config.modes.map(\.name), ModeDefinition.builtIns.map(\.name))
    }

    func testQuarantineMovesAnUnreadableConfigAside() throws {
        try Data("{ not json".utf8).write(to: store.paths.configFile)
        let backup = try XCTUnwrap(try store.quarantineUnreadableFile())
        XCTAssertFalse(store.configExists)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{ not json")
        // Nothing to move once it is gone.
        XCTAssertNil(try store.quarantineUnreadableFile())

        // A second bad config keeps the first backup.
        try Data("also broken".utf8).write(to: store.paths.configFile)
        let second = try XCTUnwrap(try store.quarantineUnreadableFile())
        XCTAssertNotEqual(second, backup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{ not json")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "also broken")
    }

    func testUnsupportedHotkeyModifiersAreRejected() throws {
        var config = VoxConfig()
        config.hotkey.modifiers = ["function"]
        XCTAssertThrowsError(try config.validate())
        XCTAssertThrowsError(try ConfigKeys.set("hotkey.modifiers", to: "function", in: &config))
        try ConfigKeys.set("hotkey.modifiers", to: "control+shift", in: &config)
        XCTAssertEqual(config.hotkey.modifiers, ["control", "shift"])
    }

    func testVoxHomeEnvironmentOverridesSupportDirectory() {
        let paths = VoxPaths(environment: ["VOX_HOME": directory.path])
        XCTAssertEqual(paths.supportDirectory.path, directory.path)
        XCTAssertEqual(paths.configFile.lastPathComponent, "config.json")
    }
}
