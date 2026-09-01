import CWhisper
import Foundation
import VoxKit

/// whisper.cpp bridge.
///
/// Contexts are expensive to build (the model is read and uploaded to the GPU),
/// so one is cached per model path and reused across recordings. `whisper_full`
/// is not reentrant, hence the serial queue.
public final class WhisperEngine: TranscriptionEngine {
    private final class ContextCache: @unchecked Sendable {
        private let lock = NSLock()
        private var modelPath: String?
        private var context: OpaquePointer?

        func context(forModelAt path: String, useGPU: Bool) throws -> OpaquePointer {
            lock.lock()
            defer { lock.unlock() }
            if let context, modelPath == path { return context }
            if let context {
                whisper_free(context)
                self.context = nil
                self.modelPath = nil
            }
            guard FileManager.default.fileExists(atPath: path) else {
                throw VoxError.model(
                    "Model file is missing",
                    detail: "\(path) — run `vox models download` first."
                )
            }
            var contextParams = whisper_context_default_params()
            contextParams.use_gpu = useGPU
            guard let created = whisper_init_from_file_with_params(path, contextParams) else {
                throw VoxError.model(
                    "whisper.cpp could not load the model",
                    detail: "\(path) — the file may be truncated or not a ggml model."
                )
            }
            self.context = created
            self.modelPath = path
            return created
        }

        func release() {
            lock.lock()
            defer { lock.unlock() }
            if let context { whisper_free(context) }
            context = nil
            modelPath = nil
        }
    }

    private let cache = ContextCache()
    private let queue = DispatchQueue(label: "ai.vox.whisper", qos: .userInitiated)
    private let useGPU: Bool

    public init(useGPU: Bool = true) {
        self.useGPU = useGPU
    }

    deinit {
        cache.release()
    }

    /// Drops the cached context and its GPU buffers. The app calls this when
    /// the user switches models or the app goes idle.
    ///
    /// Serialized on `queue` so it can never free the context out from under an
    /// in-flight `whisper_full`: `context(forModelAt:)` returns the pointer and
    /// releases its lock before the call uses it, so releasing on any other
    /// thread would be a use-after-free.
    public func unloadModel() {
        queue.sync { cache.release() }
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard !request.audio.isEmpty else {
            throw VoxError(
                code: .transcription,
                message: "No audio was captured",
                detail: "The microphone produced zero samples."
            )
        }
        // whisper.cpp needs at least one 30s-padded window's worth of signal;
        // anything under ~100ms reliably decodes to garbage or nothing.
        guard request.audio.samples.count >= Int(PCMAudio.sampleRate / 10) else {
            throw VoxError(
                code: .transcription,
                message: "Recording was too short to transcribe",
                detail: "Captured \(request.audio.durationMilliseconds)ms; at least 100ms is required."
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try runSynchronously(request))
                } catch {
                    continuation.resume(
                        throwing: VoxError.wrap(error, code: .transcription, message: "Transcription failed")
                    )
                }
            }
        }
    }

    private func runSynchronously(_ request: TranscriptionRequest) throws -> TranscriptionResult {
        let context = try cache.context(forModelAt: request.modelPath.path, useGPU: useGPU)

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(request.threadCount)
        params.translate = false
        params.no_context = true
        params.single_segment = false
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.suppress_blank = true

        // The C struct borrows these strings for the duration of the call, so
        // they must outlive `whisper_full` — hence the nested `withCString`.
        return try withOptionalCString(request.language) { languagePointer in
            try withOptionalCString(request.initialPrompt) { promptPointer in
                params.language = languagePointer
                params.initial_prompt = promptPointer

                let status = request.audio.samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                }
                guard status == 0 else {
                    throw VoxError(
                        code: .transcription,
                        message: "whisper.cpp returned error code \(status)"
                    )
                }
                return collectResult(from: context, requestedLanguage: request.language)
            }
        }
    }

    private func collectResult(
        from context: OpaquePointer,
        requestedLanguage: String?
    ) -> TranscriptionResult {
        var segments: [TranscriptSegment] = []
        let count = whisper_full_n_segments(context)
        for index in 0..<count {
            guard let raw = whisper_full_get_segment_text(context, index) else { continue }
            let text = String(cString: raw).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            // whisper.cpp timestamps are in centiseconds.
            let start = Int(whisper_full_get_segment_t0(context, index)) * 10
            let end = Int(whisper_full_get_segment_t1(context, index)) * 10
            segments.append(TranscriptSegment(text: text, startMs: start, endMs: end))
        }

        let language: String?
        if let requestedLanguage {
            language = requestedLanguage
        } else {
            let languageID = whisper_full_lang_id(context)
            language = languageID >= 0 ? whisper_lang_str(languageID).map { String(cString: $0) } : nil
        }

        return TranscriptionResult(
            text: segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            segments: segments,
            language: language
        )
    }
}

/// `withCString` that tolerates a nil string, passing NULL through to C.
private func withOptionalCString<Result>(
    _ string: String?,
    _ body: (UnsafePointer<CChar>?) throws -> Result
) throws -> Result {
    guard let string else { return try body(nil) }
    return try string.withCString { try body($0) }
}
