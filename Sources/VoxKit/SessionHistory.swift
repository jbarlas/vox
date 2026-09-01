import Foundation

public struct SessionEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var transcript: String
    public var mode: String
    public var model: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        transcript: String,
        mode: String,
        model: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.transcript = transcript
        self.mode = mode
        self.model = model
        self.createdAt = createdAt
    }
}

/// The "temp storage" surface: a bounded, user-clearable log of recent
/// transcripts, so a lost clipboard paste is recoverable.
public final class SessionHistory {
    private let paths: VoxPaths
    private let limit: Int
    private let lock = NSLock()

    public init(paths: VoxPaths = VoxPaths(), limit: Int = OutputConfig.default.sessionHistoryLimit) {
        self.paths = paths
        self.limit = max(1, limit)
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
        if entries.count > limit {
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
