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
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
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

    func testCorruptHistoryIsTreatedAsEmpty() throws {
        let paths = VoxPaths(supportDirectory: directory)
        try paths.createSupportDirectories()
        try Data("garbage".utf8).write(to: paths.sessionsFile)
        XCTAssertTrue(try history().entries().isEmpty)
    }
}
