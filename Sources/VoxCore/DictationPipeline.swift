import Foundation
import VoxKit

/// record → transcribe → mode, shared verbatim by the CLI and the menu bar app
/// so a hotkey dictation and an agent's `vox record` cannot drift apart.
public final class DictationPipeline {
    public struct Options: Sendable {
        /// Overrides `config.defaultMode`.
        public var modeName: String?
        /// Overrides `RecordingConfig.maxDurationSeconds`.
        public var timeout: Double?
        /// Transcribe this file instead of opening the microphone.
        public var inputFile: URL?
        /// Write the captured audio here for debugging.
        public var saveAudioTo: URL?

        public init(
            modeName: String? = nil,
            timeout: Double? = nil,
            inputFile: URL? = nil,
            saveAudioTo: URL? = nil
        ) {
            self.modeName = modeName
            self.timeout = timeout
            self.inputFile = inputFile
            self.saveAudioTo = saveAudioTo
        }
    }

    public enum Stage: Sendable {
        case recording
        case transcribing
        case processingMode(String)
        case finished
    }

    private let config: VoxConfig
    private let paths: VoxPaths
    private let engine: TranscriptionEngine
    private let modeRunner: ModeRunner
    private let modelManager: ModelManager
    private let capture: AudioCapture
    /// Menu bar app only; the CLI never passes one. Sees copies of the audio
    /// while recording and is discarded before transcription, so it cannot
    /// influence `RecordResult`.
    private let preview: LivePreviewRunner?
    /// Set by a stop that arrives before the microphone is open — a
    /// press-and-hold release during model loading, typically.
    private let stopRequested = Flag()

    public init(
        config: VoxConfig,
        paths: VoxPaths = VoxPaths(),
        engine: TranscriptionEngine? = nil,
        modeRunner: ModeRunner? = nil,
        modelManager: ModelManager? = nil,
        preview: LivePreviewRunner? = nil
    ) {
        self.config = config
        self.paths = paths
        self.preview = preview
        self.engine = engine ?? WhisperEngine()
        self.modeRunner = modeRunner ?? ModeRunner(llmConfig: config.llm)
        self.modelManager = modelManager ?? ModelManager(paths: paths)
        self.capture = AudioCapture(config: config.recording)
    }

    /// Stops an in-flight recording; the pipeline then continues to transcribe
    /// what it already has. This is what the hotkey release calls.
    public func stopRecording() {
        stopRequested.set()
        capture.stop()
    }

    public var isRecording: Bool { capture.isRecording }

    public func run(
        options: Options = Options(),
        onStage: (@Sendable (Stage) -> Void)? = nil,
        onLevel: (@Sendable (Double) -> Void)? = nil
    ) async throws -> RecordResult {
        let startedAt = Date()
        let modeName = options.modeName ?? config.defaultMode
        guard let mode = config.mode(named: modeName) else {
            throw VoxError.config(
                "Unknown mode '\(modeName)'",
                detail: "Defined modes: \(config.modes.map(\.name).joined(separator: ", "))"
            )
        }
        guard let model = config.resolvedModel else {
            throw VoxError.config("Unknown model '\(config.model)'")
        }

        // Resolve the model before opening the microphone: a multi-hundred-MB
        // download must not happen while the user is already talking.
        let modelPath = try await modelManager.ensureAvailable(model)
        // The preview never downloads anything: a missing preview model is
        // simply no preview, not a delay before the microphone opens.
        var previewModelPath: URL?
        if let preview, options.inputFile == nil, modelManager.isInstalled(preview.model) {
            previewModelPath = paths.modelFile(for: preview.model)
        }

        var timings = RecordTimings()
        let audio: PCMAudio
        let stopReason: StopReason

        if let inputFile = options.inputFile {
            let clock = Date()
            audio = try AudioNormalizer.pcm(fromFileAt: inputFile)
            timings.normalizeMs = Self.elapsedMs(since: clock)
            stopReason = .endOfInput
        } else {
            guard !stopRequested.isSet else {
                throw VoxError(
                    code: .cancelled,
                    message: "Recording was stopped before the microphone opened"
                )
            }
            onStage?(.recording)
            let clock = Date()
            var activePreview: LivePreviewRunner?
            if let preview, let previewModelPath {
                let capture = self.capture
                preview.start(modelPath: previewModelPath) { range in capture.samples(in: range) }
                activePreview = preview
            }
            defer { activePreview?.stop() }
            let output = try await capture.record(timeout: options.timeout) { [activePreview] event in
                switch event {
                case .level(let level): onLevel?(level)
                case .audio(let totalSamples): activePreview?.audioDidGrow(totalSamples: totalSamples)
                }
            }
            timings.recordingMs = Self.elapsedMs(since: clock)
            audio = output.audio
            stopReason = output.stopReason
        }

        if let saveAudioTo = options.saveAudioTo {
            try AudioNormalizer.writeWAV(audio, to: saveAudioTo)
        }

        onStage?(.transcribing)
        let transcribeClock = Date()
        let transcription = try await engine.transcribe(
            TranscriptionRequest(
                audio: audio,
                modelPath: modelPath,
                language: config.language,
                initialPrompt: VocabInjector.initialPrompt(vocabulary: config.vocabulary)
            )
        )
        timings.transcribeMs = Self.elapsedMs(since: transcribeClock)

        onStage?(.processingMode(mode.name))
        let modeClock = Date()
        // Whisper has already succeeded by this point, so a failure here
        // (an LLM call, typically) degrades to the raw transcript rather
        // than losing it — the caller still gets usable output, plus
        // modeError to know the mode itself didn't run.
        let modeResult: ModeResult
        let modeError: VoxError?
        do {
            modeResult = try await modeRunner.run(transcript: transcription.text, mode: mode)
            modeError = nil
        } catch {
            modeResult = ModeResult(text: transcription.text, mode: mode.name, kind: mode.kind)
            modeError = VoxError.wrap(error, code: .llm, message: "Mode '\(mode.name)' failed")
        }
        timings.modeMs = Self.elapsedMs(since: modeClock)

        let finishedAt = Date()
        timings.totalMs = Self.elapsedMs(since: startedAt, until: finishedAt)
        onStage?(.finished)

        return RecordResult(
            transcript: modeResult.text,
            rawTranscript: transcription.text,
            mode: modeResult.mode,
            modeKind: modeResult.kind,
            model: model.id,
            llmModel: modeResult.llmModel,
            language: transcription.language,
            durationMs: timings.totalMs,
            audioDurationMs: audio.durationMilliseconds,
            stopReason: stopReason,
            startedAt: startedAt,
            finishedAt: finishedAt,
            timings: timings,
            modeError: modeError
        )
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    private static func elapsedMs(since start: Date, until end: Date = Date()) -> Int {
        Int((end.timeIntervalSince(start) * 1000).rounded())
    }
}
