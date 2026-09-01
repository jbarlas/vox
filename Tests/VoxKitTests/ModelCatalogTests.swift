import XCTest

@testable import VoxKit

final class ModelCatalogTests: XCTestCase {
    func testDefaultModelExists() {
        XCTAssertEqual(ModelCatalog.defaultModel.id, ModelCatalog.defaultModelID)
    }

    func testModelIDsAndFileNamesAreUnique() {
        XCTAssertEqual(Swift.Set(ModelCatalog.all.map(\.id)).count, ModelCatalog.all.count)
        XCTAssertEqual(Swift.Set(ModelCatalog.all.map(\.fileName)).count, ModelCatalog.all.count)
    }

    func testFileNamesFollowTheGGMLConvention() {
        for model in ModelCatalog.all {
            XCTAssertEqual(model.fileName, "ggml-\(model.id).bin")
        }
    }

    func testDownloadURLsPointAtTheWhisperCppRepo() {
        let url = ModelCatalog.downloadURL(for: ModelCatalog.defaultModel)
        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
        )
    }
}

final class SessionHistoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vox-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func history(limit: Int = 3) -> SessionHistory {
        SessionHistory(paths: VoxPaths(supportDirectory: directory), limit: limit)
    }

    func testAppendKeepsNewestFirstAndEnforcesTheLimit() throws {
        let history = self.history(limit: 2)
        for index in 0..<4 {
            try history.append(SessionEntry(transcript: "entry \(index)", mode: "raw", model: "tiny.en"))
        }
        let entries = try history.entries()
        XCTAssertEqual(entries.map(\.transcript), ["entry 3", "entry 2"])
    }

    func testClearEmptiesTheLog() throws {
        let history = self.history()
        try history.append(SessionEntry(transcript: "one", mode: "raw", model: "tiny.en"))
        try history.clear()
        XCTAssertTrue(try history.entries().isEmpty)
    }

    func testNilLimitKeepsEveryEntry() throws {
        let history = SessionHistory(paths: VoxPaths(supportDirectory: directory), limit: nil)
        for index in 0..<25 {
            try history.append(SessionEntry(transcript: "entry \(index)", mode: "raw", model: "tiny.en"))
        }
        XCTAssertEqual(try history.entries().count, 25)
    }

    func testRawTranscriptRoundTrips() throws {
        let history = self.history()
        try history.append(
            SessionEntry(transcript: "cleaned up", rawTranscript: "uh cleaned up", mode: "cleanup", model: "tiny.en")
        )
        XCTAssertEqual(try history.entries().first?.rawTranscript, "uh cleaned up")
    }

    func testFailureEntryRoundTrips() throws {
        let history = self.history()
        let error = VoxError.llm("LLM endpoint at http://x didn't respond within 60s", detail: "timed out")
        try history.append(
            SessionEntry(startedAt: Date(), mode: "prompt", model: "small.en", error: error)
        )
        let entry = try XCTUnwrap(history.entries().first)
        XCTAssertEqual(entry.success, false)
        XCTAssertEqual(entry.errorCode, .llm)
        XCTAssertEqual(entry.errorMessage, error.message)
        XCTAssertEqual(entry.transcript, "")
    }

    func testOldEntryWithoutNewFieldsStillDecodes() throws {
        let paths = VoxPaths(supportDirectory: directory)
        try paths.createSupportDirectories()
        let legacyJSON = """
            [{"id":"\(UUID().uuidString)","transcript":"hello","mode":"raw","model":"tiny.en",\
            "created_at":"2026-01-01T00:00:00Z"}]
            """
        try Data(legacyJSON.utf8).write(to: paths.sessionsFile)
        let entry = try XCTUnwrap(try SessionHistory(paths: paths).entries().first)
        XCTAssertEqual(entry.transcript, "hello")
        XCTAssertNil(entry.rawTranscript)
        XCTAssertNil(entry.success)
    }

    func testCorruptHistoryIsTreatedAsEmpty() throws {
        let paths = VoxPaths(supportDirectory: directory)
        try paths.createSupportDirectories()
        try Data("garbage".utf8).write(to: paths.sessionsFile)
        XCTAssertTrue(try history().entries().isEmpty)
    }
}
