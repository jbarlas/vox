import XCTest

@testable import VoxKit

/// The mode edits the app's Modes settings and `vox modes add/remove` share.
final class ModeEditingTests: XCTestCase {
    private func llmMode(_ name: String, prompt: String = "Edit it.") -> ModeDefinition {
        ModeDefinition(name: name, kind: .llm, prompt: prompt)
    }

    func testSetModeAppendsUnknownMode() throws {
        var config = VoxConfig()
        try config.setMode(llmMode("shouty"))
        XCTAssertEqual(config.mode(named: "shouty")?.prompt, "Edit it.")
        try config.validate()
    }

    func testSetModeReplacesInPlaceKeepingOrder() throws {
        var config = VoxConfig()
        let order = config.modes.map(\.name)
        try config.setMode(llmMode("EMAIL", prompt: "New prompt."))
        XCTAssertEqual(config.modes.map(\.name), order.map { $0 == "email" ? "EMAIL" : $0 })
        XCTAssertEqual(config.mode(named: "email")?.prompt, "New prompt.")
    }

    func testSetModeRenames() throws {
        var config = VoxConfig()
        try config.setMode(llmMode("dictation"), replacing: "email")
        XCTAssertNil(config.mode(named: "email"))
        XCTAssertNotNil(config.mode(named: "dictation"))
        try config.validate()
    }

    /// `default_mode` stores a name, so a rename that didn't follow it would
    /// leave a config that no longer validates.
    func testRenamingDefaultModeMovesTheDefault() throws {
        var config = VoxConfig(defaultMode: "email")
        try config.setMode(llmMode("dictation"), replacing: "email")
        XCTAssertEqual(config.defaultMode, "dictation")
        try config.validate()
    }

    func testRenameOntoAnExistingNameIsRejected() {
        var config = VoxConfig()
        XCTAssertThrowsError(try config.setMode(llmMode("raw"), replacing: "email")) { error in
            XCTAssertEqual((error as? VoxError)?.code, .config)
        }
        XCTAssertEqual(config.mode(named: "raw")?.kind, .raw)
        XCTAssertNotNil(config.mode(named: "email"))
    }

    func testSetModeRejectsAnInvalidMode() {
        var config = VoxConfig()
        XCTAssertThrowsError(try config.setMode(ModeDefinition(name: "empty", kind: .llm)))
        XCTAssertThrowsError(try config.setMode(llmMode("  ")))
        XCTAssertEqual(config.modes.count, ModeDefinition.builtIns.count)
    }

    func testRemoveModeIsCaseInsensitive() throws {
        var config = VoxConfig()
        try config.removeMode(named: "EMAIL")
        XCTAssertNil(config.mode(named: "email"))
    }

    func testRemoveRejectsUnknownAndDefaultModes() {
        var config = VoxConfig(defaultMode: "cleanup")
        XCTAssertThrowsError(try config.removeMode(named: "nope"))
        XCTAssertThrowsError(try config.removeMode(named: "Cleanup"))
        XCTAssertEqual(config.modes.count, ModeDefinition.builtIns.count)
    }

    func testUnusedModeNameSkipsTakenNames() throws {
        var config = VoxConfig()
        XCTAssertEqual(config.unusedModeName(basedOn: "new mode"), "new mode")
        try config.setMode(llmMode("new mode"))
        XCTAssertEqual(config.unusedModeName(basedOn: "new mode"), "new mode 2")
        try config.setMode(llmMode("New Mode 2"))
        XCTAssertEqual(config.unusedModeName(basedOn: "new mode"), "new mode 3")
    }
}
