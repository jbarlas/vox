import AppKit
import Combine
import Foundation
import VoxCore
import VoxKit

/// Everything the menu bar UI observes, and the only place the app kicks off a
/// dictation. The pipeline itself is shared with the CLI.
@MainActor
final class AppState: ObservableObject {
    enum Status: Equatable {
        case idle
        case recording
        case processing
        case failed(String)

        var isBusy: Bool { self == .recording || self == .processing }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var inputLevelDB: Double = -160
    /// Live preview while recording; nil whenever the preview is off or the
    /// recording has ended. Display only — `lastTranscript` and the output
    /// router only ever see the full-pass `RecordResult`.
    @Published private(set) var previewText: String?
    @Published private(set) var history: [SessionEntry] = []
    @Published var config: VoxConfig
    /// Non-nil when the config file on disk could not be read, in which case
    /// `config` holds defaults that have deliberately not been written back.
    @Published private(set) var configLoadError: String?

    /// Called after a config save so the hotkey registration can follow.
    var onConfigChange: ((VoxConfig) -> Void)?

    private let paths: VoxPaths
    private let store: ConfigStore
    private let sessionHistory: SessionHistory
    /// Held across runs so the model stays resident on the GPU between
    /// dictations.
    private let engine = WhisperEngine()
    /// Separate engine (own whisper context, own queue) so the preview model
    /// never evicts the main one or queues behind the final pass.
    private let previewEngine = WhisperEngine()
    private let feedback: FeedbackPlayer
    private let overlay = RecordingOverlayController()
    private var pipeline: DictationPipeline?
    private var currentTask: Task<Void, Never>?

    init(paths: VoxPaths = VoxPaths()) {
        let store = ConfigStore(paths: paths)
        var loadError: String?
        var config: VoxConfig
        do {
            config = try store.load()
        } catch {
            config = VoxConfig()
            loadError =
                (error as? VoxError)?.message ?? error.localizedDescription
        }
        self.paths = paths
        self.store = store
        self.config = config
        self.configLoadError = loadError
        self.feedback = FeedbackPlayer(config: config.feedback)
        self.sessionHistory = SessionHistory(
            paths: paths,
            limit: config.output.sessionHistoryLimit
        )
        if let loadError {
            status = .failed(loadError)
        }
        refreshHistory()
    }

    // MARK: - Config

    /// Applies one change on top of whatever is on disk *right now*, not on
    /// top of `config` (which can be stale the moment something outside this
    /// process — `vox config set`, most likely — has touched the file since
    /// this app last loaded or saved it). Saving the in-memory snapshot
    /// wholesale would silently discard that outside change.
    ///
    /// Returns the message of whatever went wrong, for a caller (Settings)
    /// that has somewhere better to show a rejected edit than the menu bar.
    @discardableResult
    func save(_ mutate: (inout VoxConfig) throws -> Void) -> String? {
        do {
            // Defaults must not quietly replace a config we only failed to
            // parse. Re-read first: if the file was repaired externally since
            // launch, load it and keep the user's settings; only quarantine a
            // file that is still unreadable. The whole re-read/mutate/write
            // runs under the cross-process lock so a `vox config set` racing
            // this cannot be read stale and then overwritten.
            let fresh: VoxConfig = try store.withLock {
                var fresh: VoxConfig
                if configLoadError != nil {
                    if let repaired = try? store.load() {
                        fresh = repaired
                        configLoadError = nil
                    } else {
                        try store.quarantineUnreadableFile()
                        configLoadError = nil
                        fresh = config
                    }
                } else {
                    fresh = (try? store.load()) ?? config
                }
                try mutate(&fresh)
                try store.save(fresh)
                return fresh
            }
            config = fresh
            feedback.config = fresh.feedback
            onConfigChange?(fresh)
            return nil
        } catch {
            let message = voxMessage(for: error)
            status = .failed(message)
            return message
        }
    }

    func reloadConfig() {
        do {
            let loaded = try store.load()
            config = loaded
            feedback.config = loaded.feedback
            configLoadError = nil
        } catch {
            configLoadError = voxMessage(for: error)
        }
    }

    // MARK: - Hotkey

    func hotkeyPressed() {
        switch config.hotkey.activation {
        case .pressAndHold:
            startDictation()
        case .toggle:
            toggleDictation()
        }
    }

    func hotkeyReleased() {
        guard config.hotkey.activation == .pressAndHold else { return }
        stopDictation()
    }

    func toggleDictation() {
        if status == .recording {
            stopDictation()
        } else if status == .idle || isFailed {
            startDictation()
        }
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    // MARK: - Dictation

    func startDictation(modeName: String? = nil) {
        guard !status.isBusy else { return }
        let startedAt = Date()
        let requestedMode = modeName ?? config.defaultMode
        let preview = makePreviewRunner()
        let pipeline = DictationPipeline(config: config, paths: paths, engine: engine, preview: preview)
        self.pipeline = pipeline
        status = .recording
        inputLevelDB = -160
        previewText = nil
        feedback.playStart()
        if config.feedback.showOverlay { overlay.show(withPreview: preview != nil) }

        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await pipeline.run(
                    options: DictationPipeline.Options(modeName: modeName),
                    onStage: { stage in
                        Task { @MainActor [weak self] in self?.apply(stage: stage) }
                    },
                    onLevel: { level in
                        Task { @MainActor [weak self] in self?.apply(level: level) }
                    }
                )
                self.finish(with: result)
            } catch {
                self.fail(with: error, startedAt: startedAt, mode: requestedMode)
            }
        }
    }

    func stopDictation() {
        pipeline?.stopRecording()
    }

    private func makePreviewRunner() -> LivePreviewRunner? {
        let settings = config.livePreview
        // The overlay is the only place the preview is drawn; without it the
        // extra inference would buy nothing.
        guard settings.enabled, config.feedback.showOverlay, let model = settings.resolvedModel else {
            return nil
        }
        return LivePreviewRunner(
            config: settings,
            model: model,
            language: config.language,
            initialPrompt: VocabInjector.initialPrompt(vocabulary: config.vocabulary),
            engine: previewEngine,
            onSnapshot: { snapshot in
                Task { @MainActor [weak self] in self?.apply(preview: snapshot) }
            }
        )
    }

    private func apply(level: Double) {
        inputLevelDB = level
        overlay.update(levelDB: level)
    }

    private func apply(preview snapshot: LivePreviewSnapshot) {
        guard status == .recording else { return }
        previewText = snapshot.isEmpty ? nil : snapshot.text
        overlay.update(previewText: snapshot.text)
    }

    private func apply(stage: DictationPipeline.Stage) {
        switch stage {
        case .recording:
            status = .recording
        case .transcribing, .processingMode:
            // The stop chime belongs here, not in `stopDictation()`: a
            // recording also ends on silence or the duration cap.
            if status != .processing {
                feedback.playStop()
                overlay.setProcessing(true)
            }
            status = .processing
            previewText = nil
        case .finished:
            break
        }
    }

    private func finish(with result: RecordResult) {
        let router = OutputRouter(
            history: config.output.keepSessionHistory ? sessionHistory : nil
        )
        do {
            // The app never routes to `json`/`stdout`: there is no stdout to
            // route to, so those fall back to the clipboard.
            let destination: OutputConfig.Destination
            switch config.output.destination {
            case .json, .stdout: destination = .clipboard
            default: destination = config.output.destination
            }
            _ = try router.deliver(result: result, destination: destination)
            lastTranscript = result.transcript
            if let modeError = result.modeError {
                // Whisper still succeeded and its output was already
                // delivered above (as `result.transcript`, filled in from the
                // raw transcript) — surface the mode failure without
                // pretending the LLM step actually ran.
                status = .failed("\(modeError.message) — copied the raw transcript instead")
                feedback.playError()
            } else {
                status = .idle
                feedback.playDone()
            }
            refreshHistory()
        } catch {
            status = .failed(voxMessage(for: error))
            feedback.playError()
        }
        inputLevelDB = -160
        previewText = nil
        overlay.hide()
    }

    private func fail(with error: Error, startedAt: Date, mode: String) {
        inputLevelDB = -160
        previewText = nil
        overlay.hide()
        // A hotkey tapped and released before the microphone opened is not a
        // failure worth chiming about, or logging.
        guard (error as? VoxError)?.code != .cancelled else {
            status = .idle
            return
        }
        if config.output.keepSessionHistory {
            let voxError = (error as? VoxError) ?? VoxError.wrap(error, code: .internalError, message: voxMessage(for: error))
            try? sessionHistory.append(
                SessionEntry(startedAt: startedAt, mode: mode, model: config.model, error: voxError)
            )
            refreshHistory()
        }
        status = .failed(voxMessage(for: error))
        feedback.playError()
    }

    private func voxMessage(for error: Error) -> String {
        if let error = error as? VoxError { return error.message }
        return error.localizedDescription
    }

    // MARK: - History

    var sessionsFileURL: URL { paths.sessionsFile }

    func refreshHistory() {
        history = (try? sessionHistory.entries()) ?? []
    }

    func clearHistory() {
        try? sessionHistory.clear()
        lastTranscript = nil
        refreshHistory()
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
