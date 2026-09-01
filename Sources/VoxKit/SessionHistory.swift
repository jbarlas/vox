import Foundation

public struct SessionEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Mode output — what actually got copied/pasted.
    public var transcript: String
    /// Pre-mode whisper.cpp output, kept alongside `transcript` so this log
    /// can double as a correction/training dataset later. `nil` only for
    /// entries written before this field existed.
    public var rawTranscript: String?
    public var mode: String
    public var model: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        transcript: String,
        rawTranscript: String? = nil,
        mode: String,
        model: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.transcript = transcript
        self.rawTranscript = rawTranscript
        self.mode = mode
        self.model = model
        self.createdAt = createdAt
    }
}

/// A user-clearable log of past transcripts, for recovering a lost clipboard
/// paste and for reviewing/correcting past output. Unbounded by default
/// (`limit == nil`); set `output.session_history_limit` to cap it.
public final class SessionHistory {
    private let paths: VoxPaths
    private let limit: Int?
    private let lock = NSLock()

    public init(paths: VoxPaths = VoxPaths(), limit: Int? = OutputConfig.default.sessionHistoryLimit) {
        self.paths = paths
        self.limit = limit.map { max(1, $0) }
    }

    public func entries() throws -> [SessionEntry] {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    /// Newest first, trimmed to `limit`.
    public func append(_ entry: SessionEntry) throws {
        lock.lock()
        defer { lock.unlock() }
        var entries = (try? loadLocked()) ?? []
        entries.insert(entry, at: 0)
        if let limit, entries.count > limit {
            entries = Array(entries.prefix(limit))
        }
        try writeLocked(entries)
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        try writeLocked([])
    }

    private func loadLocked() throws -> [SessionEntry] {
        guard FileManager.default.fileExists(atPath: paths.sessionsFile.path) else { return [] }
        let data = try Data(contentsOf: paths.sessionsFile)
        // A corrupt history file must never break a transcription.
        return (try? VoxJSON.decoder().decode([SessionEntry].self, from: data)) ?? []
    }

    private func writeLocked(_ entries: [SessionEntry]) throws {
        try paths.createSupportDirectories()
        let data = try VoxJSON.encoder(pretty: true).encode(entries)
        try data.write(to: paths.sessionsFile, options: .atomic)
    }
}
