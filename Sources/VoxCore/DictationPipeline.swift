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
    /// User terms plus corpus-seeded ones, loaded once here from the cached
    /// `corpus.json` — a small JSON read, never an extraction.
    private let vocabulary: [VocabularyEntry]
    /// Set by a stop that arrives before the microphone is open — a
    /// press-and-hold release during model loading, typically.
    private let stopRequested = Flag()

    public init(
        config: VoxConfig,
        paths: VoxPaths = VoxPaths(),
        engine: TranscriptionEngine? = nil,
        modeRunner: ModeRunner? = nil,
        modelManager: ModelManager? = nil
    ) {
        self.config = config
        self.paths = paths
        self.engine = engine ?? WhisperEngine()
        self.modeRunner = modeRunner ?? ModeRunner(llmConfig: config.llm)
        self.modelManager = modelManager ?? ModelManager(paths: paths)
        self.capture = AudioCapture(config: config.recording)
        self.vocabulary = VocabularyEntry.merge(
            user: config.vocabulary,
            corpus: CorpusVocabularyStore(paths: paths).loadForInference()
        )
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
            let output = try await capture.record(timeout: options.timeout) { event in
                switch event {
                case .level(let level): onLevel?(level)
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
                initialPrompt: VocabInjector.initialPrompt(entries: vocabulary)
            )
        )
        timings.transcribeMs = Self.elapsedMs(since: transcribeClock)
        // initial_prompt only biases the decode; it doesn't force whisper to
        // spell a seeded compound term as one word over its much more common
        // split form ("Light switch" for "Lightswitch"). Rejoin those here,
        // on the raw transcript, so both it and every mode see the fix.
        let correctedText = VocabCorrector.apply(vocabulary: vocabulary.map(\.term), to: transcription.text)

        onStage?(.processingMode(mode.name))
        let modeClock = Date()
        // Whisper has already succeeded by this point, so a failure here
        // (an LLM call, typically) degrades to the raw transcript rather
        // than losing it — the caller still gets usable output, plus
        // modeError to know the mode itself didn't run.
        let modeResult: ModeResult
        let modeError: VoxError?
        do {
            modeResult = try await modeRunner.run(
                transcript: correctedText,
                mode: mode,
                vocabulary: vocabulary.map(\.term)
            )
            modeError = nil
        } catch {
            modeResult = ModeResult(text: correctedText, mode: mode.name, kind: mode.kind)
            modeError = VoxError.wrap(error, code: .llm, message: "Mode '\(mode.name)' failed")
        }
        timings.modeMs = Self.elapsedMs(since: modeClock)

        let finishedAt = Date()
        timings.totalMs = Self.elapsedMs(since: startedAt, until: finishedAt)
        onStage?(.finished)

        return RecordResult(
            transcript: modeResult.text,
            rawTranscript: correctedText,
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
