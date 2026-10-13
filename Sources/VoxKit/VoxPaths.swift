import Foundation

/// Resolves the on-disk locations shared by the CLI and the menu bar app.
///
/// `VOX_HOME` overrides the support directory, which keeps tests (and parallel
/// agent runs) off the real user configuration.
public struct VoxPaths: Sendable {
    public let supportDirectory: URL

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let override = environment["VOX_HOME"], !override.isEmpty {
            self.supportDirectory = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return
        }
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        #else
        let base = URL(
            fileURLWithPath: environment["XDG_CONFIG_HOME"]
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".config").path,
            isDirectory: true
        )
        #endif
        self.supportDirectory = base.appendingPathComponent("Vox", isDirectory: true)
    }

    public var configFile: URL { supportDirectory.appendingPathComponent("config.json") }
    public var modelsDirectory: URL { supportDirectory.appendingPathComponent("models", isDirectory: true) }
    public var sessionsFile: URL { supportDirectory.appendingPathComponent("sessions.json") }
    public var logFile: URL { supportDirectory.appendingPathComponent("vox.log") }
    public var vocabularyDirectory: URL { supportDirectory.appendingPathComponent("vocab", isDirectory: true) }
    /// Output of `vox vocab seed`; see `CorpusVocabulary`.
    public var corpusVocabularyFile: URL { vocabularyDirectory.appendingPathComponent("corpus.json") }

    /// Sidecar files `FileLock` locks, next to the documents they guard. They
    /// are never read or written — only `flock`ed — so they stay empty.
    public var configLockFile: URL { supportDirectory.appendingPathComponent("config.json.lock") }
    public var sessionsLockFile: URL { supportDirectory.appendingPathComponent("sessions.json.lock") }
    public var corpusVocabularyLockFile: URL { vocabularyDirectory.appendingPathComponent("corpus.json.lock") }

    public func modelFile(for model: WhisperModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName)
    }

    public func createSupportDirectories() throws {
        for directory in [supportDirectory, modelsDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
