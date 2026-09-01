import Foundation

/// One dictation attempt, successful or not. Every field beyond the
/// originals (`id`, `transcript`, `mode`, `model`, `createdAt`) is Optional
/// so an entry written before that field existed still decodes — a missing
/// key just becomes `nil`, never a corrupt/dropped history file.
public struct SessionEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var startedAt: Date?
    public var finishedAt: Date?
    /// Mode output — what actually got copied/pasted. Empty on failure.
    public var transcript: String
    /// Pre-mode whisper.cpp output, kept alongside `transcript` so this log
    /// can double as a correction/training dataset later.
    public var rawTranscript: String?
    public var mode: String
    public var modeKind: ModeDefinition.Kind?
    public var model: String
    /// Set only when `modeKind == .llm`.
    public var llmModel: String?
    public var language: String?
    public var stopReason: StopReason?
    public var durationMs: Int?
    public var audioDurationMs: Int?
    public var timings: RecordTimings?
    /// `nil` for entries logged before failures were tracked at all — those
    /// were only ever written on success, so treat `nil` as success too.
    public var success: Bool?
    public var errorCode: VoxErrorCode?
    public var errorMessage: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        transcript: String,
        rawTranscript: String? = nil,
        mode: String,
        modeKind: ModeDefinition.Kind? = nil,
        model: String,
        llmModel: String? = nil,
        language: String? = nil,
        stopReason: StopReason? = nil,
        durationMs: Int? = nil,
        audioDurationMs: Int? = nil,
        timings: RecordTimings? = nil,
        success: Bool? = true,
        errorCode: VoxErrorCode? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.transcript = transcript
        self.rawTranscript = rawTranscript
        self.mode = mode
        self.modeKind = modeKind
        self.model = model
        self.llmModel = llmModel
        self.language = language
        self.stopReason = stopReason
        self.durationMs = durationMs
        self.audioDurationMs = audioDurationMs
        self.timings = timings
        self.success = success
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }

    /// Built straight from a finished `RecordResult` — every debugging/
    /// fine-tuning-relevant field the pipeline already computed.
    public init(result: RecordResult) {
        self.init(
            startedAt: result.startedAt,
            finishedAt: result.finishedAt,
            transcript: result.transcript,
            rawTranscript: result.rawTranscript,
            mode: result.mode,
            modeKind: result.modeKind,
            model: result.model,
            llmModel: result.llmModel,
            language: result.language,
            stopReason: result.stopReason,
            durationMs: result.durationMs,
            audioDurationMs: result.audioDurationMs,
            timings: result.timings,
            success: result.modeError == nil,
            errorCode: result.modeError?.code,
            errorMessage: result.modeError?.message,
            createdAt: result.finishedAt
        )
    }

    /// A dictation that never produced a `RecordResult` at all.
    public init(
        startedAt: Date,
        mode: String,
        model: String,
        error: VoxError
    ) {
        self.init(
            startedAt: startedAt,
            finishedAt: Date(),
            transcript: "",
            mode: mode,
            model: model,
            success: false,
            errorCode: error.code,
            errorMessage: error.message
        )
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
        // Cross-process too: a hotkey dictation in the app and a `vox record`
        // finishing together would otherwise both read the same array and the
        // later write would drop the other's entry.
        try FileLock.withLock(at: paths.sessionsLockFile) {
            var entries = (try? loadLocked()) ?? []
            entries.insert(entry, at: 0)
            if let limit, entries.count > limit {
                entries = Array(entries.prefix(limit))
            }
            try writeLocked(entries)
        }
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        try FileLock.withLock(at: paths.sessionsLockFile) {
            try writeLocked([])
        }
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
