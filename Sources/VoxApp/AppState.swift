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
    @Published private(set) var history: [SessionEntry] = []
    @Published var config: VoxConfig
    /// Non-nil when the config file on disk could not be read, in which case
    /// `config` holds defaults that have deliberately not been written back.
    @Published private(set) var configLoadError: String?
    @Published private(set) var correctionTelemetry = CorrectionTelemetry()
    @Published private(set) var correctionCount = 0

    /// Called after a config save so the hotkey registration can follow.
    var onConfigChange: ((VoxConfig) -> Void)?

    private let paths: VoxPaths
    private let store: ConfigStore
    private let sessionHistory: SessionHistory
    /// Held across runs so the model stays resident on the GPU between
    /// dictations.
    private let engine = WhisperEngine()
    private let feedback: FeedbackPlayer
    private let overlay = RecordingOverlayController()
    private let correctionPanel = CorrectionPanelController()
    private let corrections: CorrectionStore
    private let telemetry: CorrectionTelemetryStore
    /// The dictation `lastTranscript` came from, kept whole so a fix-last edit
    /// can be logged against the raw whisper output and the mode that ran.
    private var lastResult: RecordResult?
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
        self.corrections = CorrectionStore(paths: paths)
        self.telemetry = CorrectionTelemetryStore(paths: paths)
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
        let pipeline = DictationPipeline(config: config, paths: paths, engine: engine)
        self.pipeline = pipeline
        status = .recording
        inputLevelDB = -160
        feedback.playStart()
        if config.feedback.showOverlay { overlay.show() }

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

    private func apply(level: Double) {
        inputLevelDB = level
        overlay.update(levelDB: level)
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
        case .finished:
            break
        }
    }

    private func finish(with result: RecordResult) {
        inputLevelDB = -160
        overlay.hide()
        let preview = config.corrections.preview
        guard preview.shouldShow(confidence: result.confidence), !result.transcript.isEmpty else {
            deliver(result)
            return
        }

        // Variant B: hold the transcript in the box. Whisper is done, so the
        // stop chime has played; the done chime waits for the actual delivery.
        status = .idle
        note(.invoked, for: .preview)
        correctionPanel.present(
            CorrectionPanelController.Request(
                title: "Preview",
                subtitle: result.mode,
                text: result.transcript,
                idleTimeoutSeconds: preview.idleTimeoutSeconds,
                onCommit: { [weak self] commit in
                    guard let self else { return }
                    note(commit.telemetryEvent, for: .preview)
                    if commit.changed, let record = CorrectionRecord(result: result, corrected: commit.text, variant: .preview) {
                        try? corrections.append(record)
                    }
                    var delivered = result
                    delivered.transcript = commit.text
                    // The panel has just been ordered out; give the previous
                    // app's window a moment to become key again so an
                    // auto-paste lands in it rather than in thin air.
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        self?.deliver(delivered)
                    }
                },
                onDismiss: { [weak self] in
                    guard let self else { return }
                    note(.cancelled, for: .preview)
                    // Nothing goes out, but the dictation still happened.
                    if config.output.keepSessionHistory {
                        try? sessionHistory.append(SessionEntry(result: result))
                        refreshHistory()
                    }
                    status = .idle
                }
            )
        )
    }

    private func deliver(_ result: RecordResult) {
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
            lastResult = result
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
    }

    // MARK: - Fix last (Variant A)

    func fixLastPressed() {
        guard config.corrections.fixLast.enabled, !status.isBusy, !correctionPanel.isPresenting else { return }
        guard let result = lastResult, !result.transcript.isEmpty else {
            note(.invokedEmpty, for: .fixLast)
            correctionPanel.presentEmptyState(
                title: "Fix last transcript",
                message: "Nothing to fix yet — dictate something first."
            )
            return
        }
        note(.invoked, for: .fixLast)
        correctionPanel.present(
            CorrectionPanelController.Request(
                title: "Fix last transcript",
                subtitle: result.mode,
                text: result.transcript,
                idleTimeoutSeconds: nil,
                onCommit: { [weak self] commit in
                    guard let self else { return }
                    note(commit.telemetryEvent, for: .fixLast)
                    if commit.changed, let record = CorrectionRecord(result: result, corrected: commit.text, variant: .fixLast) {
                        try? corrections.append(record)
                    }
                    // Always back to the clipboard, whatever the normal
                    // destination: the user has moved on since the paste and
                    // the caret is wherever it is now.
                    copyToClipboard(commit.text)
                    lastTranscript = commit.text
                    var updated = result
                    updated.transcript = commit.text
                    lastResult = updated
                    if isFailed { status = .idle }
                },
                onDismiss: { [weak self] in self?.note(.cancelled, for: .fixLast) }
            )
        )
    }

    private func note(_ event: CorrectionTelemetry.Event, for variant: CorrectionVariant) {
        try? telemetry.record(event, for: variant)
        correctionTelemetry = telemetry.load()
        if event == .corrected { correctionCount = corrections.count() }
    }

    var correctionsDirectoryURL: URL { corrections.directory }

    func refreshCorrectionStats() {
        correctionTelemetry = telemetry.load()
        correctionCount = corrections.count()
    }

    private func fail(with error: Error, startedAt: Date, mode: String) {
        inputLevelDB = -160
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
        lastResult = nil
        refreshHistory()
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
