import Foundation

/// Why a recording ended. Agents branch on this to distinguish "the user
/// finished speaking" from "we hit the deadline".
public enum StopReason: String, Codable, Sendable {
    case silence
    case timeout
    case maxDuration
    case manual
    case endOfInput
}

public struct RecordTimings: Codable, Sendable, Equatable {
    public var recordingMs: Int
    public var normalizeMs: Int
    public var transcribeMs: Int
    public var modeMs: Int
    public var totalMs: Int

    public init(
        recordingMs: Int = 0,
        normalizeMs: Int = 0,
        transcribeMs: Int = 0,
        modeMs: Int = 0,
        totalMs: Int = 0
    ) {
        self.recordingMs = recordingMs
        self.normalizeMs = normalizeMs
        self.transcribeMs = transcribeMs
        self.modeMs = modeMs
        self.totalMs = totalMs
    }
}

public struct RecordResult: Codable, Sendable, Equatable {
    /// Mode output. This is the field an agent should read.
    public var transcript: String
    /// Pre-mode whisper.cpp output, so a caller can audit what a mode changed.
    public var rawTranscript: String
    public var mode: String
    public var modeKind: ModeDefinition.Kind
    public var model: String
    public var llmModel: String?
    public var language: String?
    public var durationMs: Int
    public var audioDurationMs: Int
    public var stopReason: StopReason
    public var startedAt: Date
    public var finishedAt: Date
    public var timings: RecordTimings
    /// Set when the mode step (an LLM call, typically) failed and `transcript`
    /// was filled in from `rawTranscript` instead — whisper.cpp already
    /// succeeded by that point, so a mode failure degrades the output rather
    /// than losing it. `nil` means the mode ran cleanly.
    public var modeError: VoxError?

    public init(
        transcript: String,
        rawTranscript: String,
        mode: String,
        modeKind: ModeDefinition.Kind,
        model: String,
        llmModel: String? = nil,
        language: String?,
        durationMs: Int,
        audioDurationMs: Int,
        stopReason: StopReason,
        startedAt: Date,
        finishedAt: Date,
        timings: RecordTimings,
        modeError: VoxError? = nil
    ) {
        self.transcript = transcript
        self.rawTranscript = rawTranscript
        self.mode = mode
        self.modeKind = modeKind
        self.model = model
        self.llmModel = llmModel
        self.language = language
        self.durationMs = durationMs
        self.audioDurationMs = audioDurationMs
        self.stopReason = stopReason
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.timings = timings
        self.modeError = modeError
    }
}

/// The exact document `vox record --output json` prints, success or failure.
///
/// `ok` is the only field a caller must check; `schema_version` is bumped only
/// on a breaking change to the field set.
public struct RecordEnvelope: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var ok: Bool
    public var result: RecordResult?
    public var error: VoxError?

    public init(result: RecordResult) {
        self.schemaVersion = Self.currentSchemaVersion
        self.ok = true
        self.result = result
        self.error = nil
    }

    public init(error: VoxError) {
        self.schemaVersion = Self.currentSchemaVersion
        self.ok = false
        self.result = nil
        self.error = error
    }
}
