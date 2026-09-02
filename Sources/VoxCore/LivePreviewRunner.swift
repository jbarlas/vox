import Foundation
import VoxKit

/// Runs `LivePreviewScheduler` against a real engine while a recording is in
/// progress. Owns nothing the final pass depends on: it reads copies of the
/// capture buffer, transcribes them on its own engine (and therefore its own
/// whisper context and serial queue), and only ever reports snapshots to a
/// UI callback. Failures are swallowed — a broken preview is just no preview.
public final class LivePreviewRunner: @unchecked Sendable {
    public typealias SampleReader = (Range<Int>) -> [Float]

    public let model: WhisperModel
    private let language: String?
    private let initialPrompt: String?
    private let engine: TranscriptionEngine
    private let onSnapshot: @Sendable (LivePreviewSnapshot) -> Void
    private let lock = NSLock()
    private var scheduler: LivePreviewScheduler
    private var modelPath: URL?
    private var reader: SampleReader?

    /// Preview competes with the microphone thread and, later, the final
    /// pass; half the cores keeps it from starving either.
    private let threadCount = max(1, TranscriptionRequest.defaultThreadCount / 2)

    public init(
        config: LivePreviewConfig,
        model: WhisperModel,
        language: String?,
        initialPrompt: String?,
        engine: TranscriptionEngine,
        onSnapshot: @escaping @Sendable (LivePreviewSnapshot) -> Void
    ) {
        self.model = model
        self.language = language
        self.initialPrompt = initialPrompt
        self.engine = engine
        self.onSnapshot = onSnapshot
        self.scheduler = LivePreviewScheduler(config: config, sampleRate: PCMAudio.sampleRate)
    }

    /// Begins previewing a recording whose samples `reader` can copy out.
    public func start(modelPath: URL, reader: @escaping SampleReader) {
        lock.lock()
        scheduler.start()
        self.modelPath = modelPath
        self.reader = reader
        lock.unlock()
    }

    /// Discards the preview. Results still in flight are dropped when they land.
    public func stop() {
        lock.lock()
        scheduler.stop()
        reader = nil
        lock.unlock()
        onSnapshot(LivePreviewSnapshot())
    }

    /// Called from the capture tap; returns immediately, kicking off at most
    /// one inference.
    public func audioDidGrow(totalSamples: Int) {
        lock.lock()
        scheduler.audioDidGrow(totalSamples: totalSamples)
        guard let request = scheduler.nextRequest(now: Date()), let reader, let modelPath else {
            lock.unlock()
            return
        }
        lock.unlock()

        let samples = reader(request.sampleRange)
        let transcription = TranscriptionRequest(
            audio: PCMAudio(samples: samples),
            modelPath: modelPath,
            language: language,
            initialPrompt: initialPrompt,
            threadCount: threadCount
        )
        Task.detached(priority: .utility) { [self] in
            do {
                let result = try await engine.transcribe(transcription)
                apply(request, text: result.text)
            } catch {
                lock.lock()
                scheduler.fail(request)
                lock.unlock()
            }
        }
    }

    private func apply(_ request: LivePreviewRequest, text: String) {
        lock.lock()
        let snapshot = scheduler.complete(request, text: text)
        lock.unlock()
        if let snapshot { onSnapshot(snapshot) }
    }
}
