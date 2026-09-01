import Foundation
import VoxKit

public struct TranscriptSegment: Sendable, Equatable {
    public let text: String
    public let startMs: Int
    public let endMs: Int

    public init(text: String, startMs: Int, endMs: Int) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    public let segments: [TranscriptSegment]
    /// Detected language, or the pinned one when config forced it.
    public let language: String?

    public init(text: String, segments: [TranscriptSegment], language: String?) {
        self.text = text
        self.segments = segments
        self.language = language
    }
}

public struct TranscriptionRequest: Sendable {
    public var audio: PCMAudio
    public var modelPath: URL
    /// `nil` asks the engine to auto-detect.
    public var language: String?
    /// Vocabulary biasing, from `VocabInjector`.
    public var initialPrompt: String?
    public var threadCount: Int

    public init(
        audio: PCMAudio,
        modelPath: URL,
        language: String?,
        initialPrompt: String?,
        threadCount: Int = TranscriptionRequest.defaultThreadCount
    ) {
        self.audio = audio
        self.modelPath = modelPath
        self.language = language
        self.initialPrompt = initialPrompt
        self.threadCount = threadCount
    }

    /// Leaves a core for the UI/OS; whisper.cpp gains little past 8 threads.
    public static var defaultThreadCount: Int {
        max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))
    }
}

/// The seam that keeps a second engine (Core ML, MLX, a cloud API) addable
/// without touching the pipeline. Only whisper.cpp ships in v1.
public protocol TranscriptionEngine: Sendable {
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}
