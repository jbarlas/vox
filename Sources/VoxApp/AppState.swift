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

    /// Called after a config save so the hotkey registration can follow.
    var onConfigChange: ((VoxConfig) -> Void)?

    private let paths: VoxPaths
    private let store: ConfigStore
    private let sessionHistory: SessionHistory
    /// Held across runs so the model stays resident on the GPU between
    /// dictations.
    private let engine = WhisperEngine()
    private var pipeline: DictationPipeline?
    private var currentTask: Task<Void, Never>?

    init(paths: VoxPaths = VoxPaths()) {
        self.paths = paths
        self.store = ConfigStore(paths: paths)
        self.config = (try? store.load()) ?? VoxConfig()
        self.sessionHistory = SessionHistory(
            paths: paths,
            limit: config.output.sessionHistoryLimit
        )
        refreshHistory()
    }

    // MARK: - Config

    func save(_ newConfig: VoxConfig) {
        do {
            try store.save(newConfig)
            config = newConfig
            onConfigChange?(newConfig)
        } catch {
            status = .failed(voxMessage(for: error))
        }
    }

    func reloadConfig() {
        if let loaded = try? store.load() {
            config = loaded
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
        let pipeline = DictationPipeline(config: config, paths: paths, engine: engine)
        self.pipeline = pipeline
        status = .recording
        inputLevelDB = -160

        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await pipeline.run(
                    options: DictationPipeline.Options(modeName: modeName),
                    onStage: { stage in
                        Task { @MainActor [weak self] in self?.apply(stage: stage) }
                    },
                    onLevel: { level in
                        Task { @MainActor [weak self] in self?.inputLevelDB = level }
                    }
                )
                self.finish(with: result)
            } catch {
                self.fail(with: error)
            }
        }
    }

    func stopDictation() {
        pipeline?.stopRecording()
    }

    private func apply(stage: DictationPipeline.Stage) {
        switch stage {
        case .recording:
            status = .recording
        case .transcribing, .processingMode:
            status = .processing
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
            status = .idle
            refreshHistory()
        } catch {
            status = .failed(voxMessage(for: error))
        }
        inputLevelDB = -160
    }

    private func fail(with error: Error) {
        status = .failed(voxMessage(for: error))
        inputLevelDB = -160
    }

    private func voxMessage(for error: Error) -> String {
        if let error = error as? VoxError { return error.message }
        return error.localizedDescription
    }

    // MARK: - History

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
