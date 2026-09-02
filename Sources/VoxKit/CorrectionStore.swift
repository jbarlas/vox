import Foundation

/// Which UX surface produced a correction, so the two can be compared.
public enum CorrectionVariant: String, Codable, Sendable, CaseIterable {
    /// The "fix last transcript" hotkey, after delivery.
    case fixLast
    /// The pre-paste preview box, before delivery.
    case preview
}

/// One observed (what Vox produced, what the user actually wanted) pair — the
/// only ground-truth correction signal Vox can see, since it is captured while
/// the text is still inside Vox.
public struct CorrectionRecord: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var variant: CorrectionVariant
    /// whisper.cpp output before any mode ran.
    public var rawTranscript: String
    /// What the user was shown and edited — the mode's output, which equals
    /// `rawTranscript` for the raw mode.
    public var originalTranscript: String
    public var correctedTranscript: String
    public var mode: String
    public var modeKind: ModeDefinition.Kind
    public var model: String
    public var llmModel: String?
    public var language: String?
    public var confidence: TranscriptConfidence?
    /// When the dictation this corrects finished, to line it up with
    /// `sessions.json`.
    public var dictationFinishedAt: Date?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        variant: CorrectionVariant,
        rawTranscript: String,
        originalTranscript: String,
        correctedTranscript: String,
        mode: String,
        modeKind: ModeDefinition.Kind,
        model: String,
        llmModel: String? = nil,
        language: String? = nil,
        confidence: TranscriptConfidence? = nil,
        dictationFinishedAt: Date? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.createdAt = createdAt
        self.variant = variant
        self.rawTranscript = rawTranscript
        self.originalTranscript = originalTranscript
        self.correctedTranscript = correctedTranscript
        self.mode = mode
        self.modeKind = modeKind
        self.model = model
        self.llmModel = llmModel
        self.language = language
        self.confidence = confidence
        self.dictationFinishedAt = dictationFinishedAt
    }

    /// Builds the record for `result` edited to `corrected`, or `nil` when the
    /// edit changed nothing worth learning from (whitespace-only differences
    /// included): confirming an already-correct transcript is a usage signal,
    /// not a correction.
    public init?(
        result: RecordResult, corrected: String, variant: CorrectionVariant, createdAt: Date = Date()
    ) {
        guard Self.isMeaningfulChange(from: result.transcript, to: corrected) else { return nil }
        self.init(
            createdAt: createdAt,
            variant: variant,
            rawTranscript: result.rawTranscript,
            originalTranscript: result.transcript,
            correctedTranscript: corrected.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: result.mode,
            modeKind: result.modeKind,
            model: result.model,
            llmModel: result.llmModel,
            language: result.language,
            confidence: result.confidence,
            dictationFinishedAt: result.finishedAt
        )
    }

    public static func isMeaningfulChange(from original: String, to corrected: String) -> Bool {
        let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != original.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Correction pairs on disk: one pretty-printed JSON file per record under
/// `VoxPaths.correctionsDirectory`, named so a plain `ls` sorts them in time
/// order. One file per record needs no cross-process locking and never grows
/// into a single document that has to be rewritten whole to append to.
public final class CorrectionStore {
    private let paths: VoxPaths

    public init(paths: VoxPaths = VoxPaths()) {
        self.paths = paths
    }

    public var directory: URL { paths.correctionsDirectory }

    @discardableResult
    public func append(_ record: CorrectionRecord) throws -> URL {
        try FileManager.default.createDirectory(
            at: paths.correctionsDirectory, withIntermediateDirectories: true)
        let url = paths.correctionsDirectory.appendingPathComponent(Self.fileName(for: record))
        let data = try VoxJSON.encoder(pretty: true).encode(record)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Oldest first. Files that fail to decode are skipped rather than failing
    /// the whole read: a training export must not be blocked by one bad file.
    public func records() throws -> [CorrectionRecord] {
        guard FileManager.default.fileExists(atPath: paths.correctionsDirectory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: paths.correctionsDirectory,
            includingPropertiesForKeys: nil
        )
        let decoder = VoxJSON.decoder()
        return
            files
            .filter {
                $0.pathExtension == "json"
                    && $0.lastPathComponent != paths.correctionTelemetryFile.lastPathComponent
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(CorrectionRecord.self, from: data)
            }
    }

    public func count() -> Int {
        (try? records().count) ?? 0
    }

    /// `2026-09-02T03-54-11Z-<uuid>.json`: ISO-8601 with the colons replaced,
    /// since they are illegal in file names on some volumes.
    static func fileName(for record: CorrectionRecord) -> String {
        let stamp = ISO8601.string(from: record.createdAt).replacingOccurrences(of: ":", with: "-")
        return "\(stamp)-\(record.id.uuidString.lowercased()).json"
    }
}
