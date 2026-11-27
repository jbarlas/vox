import Foundation

/// What the floating dictation HUD is showing. Platform-independent so the
/// transitions can be unit-tested without AppKit; `RecordingOverlayController`
/// only renders whatever phase `HUDStateMachine` hands it.
public enum HUDPhase: Equatable, Sendable {
    case hidden
    /// The dictation has begun but the microphone isn't open yet (model
    /// resolution, audio engine start).
    case starting
    case recording(since: Date)
    case transcribing
    /// An LLM request for `mode` (going to `model`, when known) is in flight.
    case refining(mode: String, model: String?, since: Date)
    case succeeded(HUDOutcome)
    case failed(HUDFailure)

    /// Order of the in-flight phases. Stage callbacks hop to the main actor
    /// in separate tasks, so one can land late; ranking them keeps the HUD
    /// from ever stepping backwards (e.g. "Transcribing" after "Refining").
    var progressRank: Int {
        switch self {
        case .hidden: return 0
        case .starting: return 1
        case .recording: return 2
        case .transcribing: return 3
        case .refining: return 4
        case .succeeded, .failed: return 5
        }
    }

    public var isTerminal: Bool { progressRank == 5 }
}

public struct HUDOutcome: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case success
        /// Nothing went wrong, but nothing useful came out either.
        case notice
    }

    public var style: Style
    public var title: String
    public var detail: String?

    public init(style: Style = .success, title: String, detail: String? = nil) {
        self.style = style
        self.title = title
        self.detail = detail
    }
}

public struct HUDFailure: Equatable, Sendable {
    /// What went wrong, short enough for one line ("LLM timed out after 60s").
    public var title: String
    /// Second line when there is no fallback note.
    public var detail: String?
    /// Set when the raw transcript was still delivered, so the user knows
    /// they didn't lose what they said. Shown in place of `detail`, which is
    /// why the reason itself lives in `title`.
    public var fallbackNote: String?

    public init(title: String, detail: String? = nil, fallbackNote: String? = nil) {
        self.title = title
        self.detail = detail
        self.fallbackNote = fallbackNote
    }
}

public enum HUDEvent: Equatable, Sendable {
    case began
    case recordingStarted(at: Date)
    case transcriptionStarted
    case modeStarted(name: String, usesLLM: Bool, model: String? = nil, at: Date)
    /// The result was handed to its destination. `modeError` set means the
    /// mode failed and the raw transcript was delivered instead.
    case delivered(Delivery)
    /// The dictation failed outright: nothing was delivered.
    case failed(VoxError)
    case cancelled
    /// The auto-dismiss timer for dictation `generation` fired.
    case dismissed(generation: Int)
}

public struct Delivery: Equatable, Sendable {
    public var destination: OutputConfig.Destination
    public var transcriptIsEmpty: Bool
    public var mode: String
    public var usedLLM: Bool
    public var modeError: VoxError?
    public var modeElapsed: TimeInterval

    public init(
        destination: OutputConfig.Destination,
        transcriptIsEmpty: Bool,
        mode: String,
        usedLLM: Bool,
        modeError: VoxError? = nil,
        modeElapsed: TimeInterval = 0
    ) {
        self.destination = destination
        self.transcriptIsEmpty = transcriptIsEmpty
        self.mode = mode
        self.usedLLM = usedLLM
        self.modeError = modeError
        self.modeElapsed = modeElapsed
    }
}

public struct HUDStateMachine: Sendable {
    public private(set) var phase: HUDPhase = .hidden
    /// Bumped on every `.began`, so an auto-dismiss scheduled for one
    /// dictation can never hide the next one.
    public private(set) var generation = 0

    public init() {}

    public mutating func send(_ event: HUDEvent) {
        switch event {
        case .began:
            generation += 1
            phase = .starting
        case .recordingStarted(let at):
            advance(to: .recording(since: at))
        case .transcriptionStarted:
            advance(to: .transcribing)
        case .modeStarted(let name, let usesLLM, let model, let at):
            // A raw/cleanup mode is instantaneous: flashing a separate phase
            // for it would only be noise.
            guard usesLLM else { return }
            advance(to: .refining(mode: name, model: model, since: at))
        case .delivered(let delivery):
            guard phase != .hidden else { return }
            phase = Self.phase(for: delivery)
        case .failed(let error):
            guard phase != .hidden else { return }
            phase = .failed(Self.failure(for: error))
        case .cancelled:
            phase = .hidden
        case .dismissed(let generation):
            guard generation == self.generation, phase.isTerminal else { return }
            phase = .hidden
        }
    }

    private mutating func advance(to next: HUDPhase) {
        guard phase != .hidden, !phase.isTerminal, next.progressRank > phase.progressRank else { return }
        phase = next
    }

    /// How long a terminal phase stays up before it dismisses itself. `nil`
    /// for in-flight phases, which stay up until the next event.
    public static func autoDismissDelay(for phase: HUDPhase) -> TimeInterval? {
        switch phase {
        case .succeeded(let outcome): return outcome.style == .success ? 1.4 : 2.2
        case .failed(let failure): return failure.fallbackNote == nil ? 4.5 : 4.0
        default: return nil
        }
    }

    // MARK: - Copy

    static func phase(for delivery: Delivery) -> HUDPhase {
        if let modeError = delivery.modeError {
            var failure = llmFailure(for: modeError, elapsed: delivery.modeElapsed)
            failure.fallbackNote = fallbackNote(for: delivery.destination)
            return .failed(failure)
        }
        if delivery.transcriptIsEmpty {
            return .succeeded(HUDOutcome(style: .notice, title: "No speech detected"))
        }
        let detail = delivery.usedLLM
            ? "Refined with \(delivery.mode) · \(formatSeconds(delivery.modeElapsed))"
            : nil
        return .succeeded(HUDOutcome(title: deliveredTitle(for: delivery.destination), detail: detail))
    }

    static func deliveredTitle(for destination: OutputConfig.Destination) -> String {
        switch destination {
        case .clipboard, .json, .stdout: return "Copied"
        case .autoPaste: return "Pasted"
        case .none: return "Done"
        }
    }

    static func fallbackNote(for destination: OutputConfig.Destination) -> String {
        switch destination {
        case .clipboard, .json, .stdout: return "Raw transcript copied instead"
        case .autoPaste: return "Raw transcript pasted instead"
        case .none: return "Kept the raw transcript instead"
        }
    }

    static func llmFailure(for error: VoxError, elapsed: TimeInterval) -> HUDFailure {
        switch LLMFailureKind.classify(error) {
        case .timeout:
            return HUDFailure(title: "LLM timed out after \(formatSeconds(elapsed))", detail: error.message)
        case .unreachable:
            return HUDFailure(title: "LLM unreachable", detail: "Is the endpoint running?")
        case .emptyResponse:
            return HUDFailure(title: "LLM returned an empty reply", detail: error.message)
        case .httpStatus(let status):
            return HUDFailure(title: "LLM error · HTTP \(status)", detail: error.message)
        case .invalidResponse:
            return HUDFailure(title: "LLM reply unreadable", detail: error.message)
        case .misconfigured:
            return HUDFailure(title: "LLM not configured", detail: error.message)
        case .other:
            return HUDFailure(title: "LLM step failed", detail: error.message)
        }
    }

    static func failure(for error: VoxError) -> HUDFailure {
        let title: String
        switch error.code {
        case .microphone: title = "Microphone unavailable"
        case .permission: title = "Microphone access needed"
        case .audio: title = "Audio problem"
        case .model: title = "Model unavailable"
        case .transcription: title = "Transcription failed"
        case .output: title = "Couldn't deliver the text"
        case .config: title = "Configuration problem"
        case .llm: title = "LLM step failed"
        case .timeout: title = "Timed out"
        case .cancelled, .internalError: title = "Dictation failed"
        }
        return HUDFailure(title: title, detail: error.message)
    }

    static func formatSeconds(_ seconds: TimeInterval) -> String {
        seconds < 10
            ? String(format: "%.1fs", max(0, seconds))
            : "\(Int(seconds.rounded()))s"
    }
}

/// Coarse buckets for an LLM failure, so the HUD can say *what* went wrong
/// in a few words. Matches the messages `LiteLLMClient` throws, pinned by
/// `LLMFailureMessage` so the two can't drift apart silently.
public enum LLMFailureKind: Equatable, Sendable {
    case unreachable
    case timeout
    case emptyResponse
    case httpStatus(Int)
    case invalidResponse
    case misconfigured
    case other

    public static func classify(_ error: VoxError) -> LLMFailureKind {
        let message = error.message
        if error.code == .config { return .misconfigured }
        if message.contains(LLMFailureMessage.timeoutMarker) { return .timeout }
        if message.hasPrefix(LLMFailureMessage.unreachablePrefix) { return .unreachable }
        if message == LLMFailureMessage.emptyResponse { return .emptyResponse }
        if message == LLMFailureMessage.invalidResponse { return .invalidResponse }
        if message.hasPrefix(LLMFailureMessage.httpStatusPrefix),
            let status = Int(message.dropFirst(LLMFailureMessage.httpStatusPrefix.count))
        {
            return .httpStatus(status)
        }
        // `LiteLLMClient.init`'s missing-API-key error (code .llm).
        if message.contains("is not set") || message.contains("not a valid URL") { return .misconfigured }
        return .other
    }
}

/// The user-facing messages `LiteLLMClient`/`ModeRunner` throw for each kind
/// of LLM failure, shared with `LLMFailureKind.classify`.
public enum LLMFailureMessage {
    static let timeoutMarker = "didn't respond within"
    static let unreachablePrefix = "Could not reach the LLM endpoint"
    static let httpStatusPrefix = "LLM endpoint returned HTTP "
    public static let emptyResponse = "LLM response contained no message content"
    public static let invalidResponse = "LLM response was not valid chat-completions JSON"

    static func timeout(endpoint: String, seconds: TimeInterval) -> String {
        "LLM endpoint at \(endpoint) \(timeoutMarker) \(Int(seconds))s"
    }

    static func unreachable(endpoint: String) -> String {
        "\(unreachablePrefix) at \(endpoint)"
    }

    static func httpStatus(_ status: Int) -> String {
        "\(httpStatusPrefix)\(status)"
    }
}
