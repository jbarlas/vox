import Foundation

/// The single configuration document shared by the CLI and the menu bar app, so
/// a hotkey-triggered dictation and an agent's `vox record` behave identically.
public struct VoxConfig: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var model: String
    public var defaultMode: String
    /// `nil` lets whisper.cpp auto-detect. "en" pins English, which is both
    /// faster and more accurate when the user only ever dictates English.
    public var language: String?
    public var vocabulary: [String]
    public var hotkey: HotkeyConfig
    public var recording: RecordingConfig
    public var output: OutputConfig
    public var feedback: FeedbackConfig
    public var llm: LLMConfig
    public var modes: [ModeDefinition]

    public init(
        schemaVersion: Int = VoxConfig.currentSchemaVersion,
        model: String = ModelCatalog.defaultModelID,
        defaultMode: String = ModeDefinition.raw.name,
        language: String? = "en",
        vocabulary: [String] = [],
        hotkey: HotkeyConfig = .default,
        recording: RecordingConfig = .default,
        output: OutputConfig = .default,
        feedback: FeedbackConfig = .default,
        llm: LLMConfig = .default,
        modes: [ModeDefinition] = ModeDefinition.builtIns
    ) {
        self.schemaVersion = schemaVersion
        self.model = model
        self.defaultMode = defaultMode
        self.language = language
        self.vocabulary = vocabulary
        self.hotkey = hotkey
        self.recording = recording
        self.output = output
        self.feedback = feedback
        self.llm = llm
        self.modes = modes
    }

    /// Every section is optional on read so a config written by an older build
    /// keeps working when a new section is added; only `schemaVersion` guards
    /// compatibility, and it guards it in one direction.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VoxConfig()
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? defaults.schemaVersion
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
        defaultMode = try container.decodeIfPresent(String.self, forKey: .defaultMode)
            ?? defaults.defaultMode
        language = try container.decodeIfPresent(String.self, forKey: .language)
        vocabulary = try container.decodeIfPresent([String].self, forKey: .vocabulary) ?? []
        hotkey = try container.decodeIfPresent(HotkeyConfig.self, forKey: .hotkey) ?? .default
        recording = try container.decodeIfPresent(RecordingConfig.self, forKey: .recording) ?? .default
        output = try container.decodeIfPresent(OutputConfig.self, forKey: .output) ?? .default
        feedback = try container.decodeIfPresent(FeedbackConfig.self, forKey: .feedback) ?? .default
        llm = try container.decodeIfPresent(LLMConfig.self, forKey: .llm) ?? .default
        modes = try container.decodeIfPresent([ModeDefinition].self, forKey: .modes)
            ?? ModeDefinition.builtIns
    }

    public func mode(named name: String) -> ModeDefinition? {
        modes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public var resolvedModel: WhisperModel? {
        ModelCatalog.model(id: model)
    }

    /// Rejects documents that would fail confusingly deeper in the pipeline.
    public func validate() throws {
        guard schemaVersion <= VoxConfig.currentSchemaVersion else {
            throw VoxError.config(
                "Config schema version \(schemaVersion) is newer than this build supports (\(VoxConfig.currentSchemaVersion))",
                detail: "Upgrade Vox or delete the config file to regenerate it."
            )
        }
        guard ModelCatalog.model(id: model) != nil else {
            throw VoxError.config(
                "Unknown model '\(model)'",
                detail: "Known models: \(ModelCatalog.all.map(\.id).joined(separator: ", "))"
            )
        }
        guard mode(named: defaultMode) != nil else {
            throw VoxError.config(
                "Default mode '\(defaultMode)' is not defined",
                detail: "Defined modes: \(modes.map(\.name).joined(separator: ", "))"
            )
        }
        var seen = Set<String>()
        for mode in modes {
            let key = mode.name.lowercased()
            guard seen.insert(key).inserted else {
                throw VoxError.config("Duplicate mode name '\(mode.name)'")
            }
            try mode.validate()
        }
        try recording.validate()
        try feedback.validate()
        try hotkey.validate()
        try output.validate()
    }
}

/// Audible and on-screen confirmation that Vox is listening. Purely a menu bar
/// app concern: the CLI writes to stderr instead and stays quiet.
public struct FeedbackConfig: Codable, Sendable, Equatable {
    /// Names of the sounds shipped in `/System/Library/Sounds`, which
    /// `NSSound(named:)` resolves without bundling any audio.
    public static let systemSoundNames = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    public var soundsEnabled: Bool
    /// `nil` plays nothing for that event. Any name under `/System/Library/Sounds`
    /// or `~/Library/Sounds` works, not only `systemSoundNames`.
    public var startSound: String?
    /// Plays the instant recording ends, before transcription or a mode
    /// starts — confirms the mic closed, not that output is ready.
    public var stopSound: String?
    /// Plays once the transcript (and mode, if any) has actually finished and
    /// been delivered. Distinct from `stopSound`: an LLM mode can easily run
    /// several seconds after recording stops, and without this there was no
    /// audible cue at all for when a dictation was actually done.
    public var doneSound: String?
    public var errorSound: String?
    /// The floating waveform strip at the top of the screen while recording.
    public var showOverlay: Bool

    public init(
        soundsEnabled: Bool = true,
        startSound: String? = "Morse",
        stopSound: String? = "Pop",
        doneSound: String? = "Glass",
        errorSound: String? = "Basso",
        showOverlay: Bool = true
    ) {
        self.soundsEnabled = soundsEnabled
        self.startSound = startSound
        self.stopSound = stopSound
        self.doneSound = doneSound
        self.errorSound = errorSound
        self.showOverlay = showOverlay
    }

    public static let `default` = FeedbackConfig()

    public func validate() throws {
        for name in [startSound, stopSound, doneSound, errorSound].compactMap({ $0 }) where name.isEmpty {
            throw VoxError.config(
                "feedback sound names must be non-empty",
                detail: "Use null to disable a sound."
            )
        }
    }
}

public struct HotkeyConfig: Codable, Sendable, Equatable {
    public enum Activation: String, Codable, Sendable {
        /// Records while the chord is held, transcribes on release.
        case pressAndHold
        /// First press starts, second press stops.
        case toggle
    }

    /// Carbon/`CGKeyCode` virtual key code. 49 is Space.
    public var keyCode: UInt16
    /// The modifiers a Carbon hotkey registration can express. Anything else
    /// would have to be silently dropped, turning ⌥Space into bare Space.
    public static let supportedModifiers: Set<String> = [
        "command", "option", "control", "shift",
    ]

    /// Any of `supportedModifiers`.
    public var modifiers: [String]
    public var activation: Activation
    public var enabled: Bool

    public init(keyCode: UInt16, modifiers: [String], activation: Activation, enabled: Bool = true) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.activation = activation
        self.enabled = enabled
    }

    /// Control+Option+Space, press-and-hold: not claimed by macOS or common
    /// editors, and holding matches how dictation is actually used
    /// mid-thought.
    public static let `default` = HotkeyConfig(
        keyCode: 49,
        modifiers: ["control", "option"],
        activation: .pressAndHold
    )

    public func validate() throws {
        for modifier in modifiers where !Self.supportedModifiers.contains(modifier.lowercased()) {
            throw VoxError.config(
                "Unsupported hotkey modifier '\(modifier)'",
                detail: "Supported: \(Self.supportedModifiers.sorted().joined(separator: ", "))"
            )
        }
        // A bare key (no modifier) would register globally and swallow ordinary
        // typing, so reject it when the hotkey is enabled.
        guard !enabled || !modifiers.isEmpty else {
            throw VoxError.config(
                "An enabled hotkey needs at least one modifier",
                detail: "Supported: \(Self.supportedModifiers.sorted().joined(separator: ", "))"
            )
        }
    }
}

public struct RecordingConfig: Codable, Sendable, Equatable {
    /// Hard ceiling on a single recording; also the CLI's default `--timeout`.
    public var maxDurationSeconds: Double
    /// Stop after this much trailing silence. `nil` disables silence detection.
    public var silenceTimeoutSeconds: Double?
    /// RMS level (dBFS) below which audio counts as silence.
    public var silenceThresholdDB: Double
    /// `nil` uses the system default input device.
    public var inputDeviceUID: String?

    public init(
        maxDurationSeconds: Double = 120,
        silenceTimeoutSeconds: Double? = 2.0,
        silenceThresholdDB: Double = -45,
        inputDeviceUID: String? = nil
    ) {
        self.maxDurationSeconds = maxDurationSeconds
        self.silenceTimeoutSeconds = silenceTimeoutSeconds
        self.silenceThresholdDB = silenceThresholdDB
        self.inputDeviceUID = inputDeviceUID
    }

    public static let `default` = RecordingConfig()

    /// Acronyms need spelled-out keys: snake_case conversion is not symmetric
    /// for them. `silenceThresholdDB` encodes as `silence_threshold_db` but
    /// decodes back as `silenceThresholdDb`, so the key is written in the form
    /// the decoder produces and the encoder converts it the same way.
    enum CodingKeys: String, CodingKey {
        case maxDurationSeconds
        case silenceTimeoutSeconds
        case silenceThresholdDB = "silenceThresholdDb"
        case inputDeviceUID = "inputDeviceUid"
    }

    public func validate() throws {
        guard maxDurationSeconds > 0 else {
            throw VoxError.config("recording.max_duration_seconds must be greater than 0")
        }
        if let silenceTimeoutSeconds, silenceTimeoutSeconds <= 0 {
            throw VoxError.config("recording.silence_timeout_seconds must be greater than 0 or null")
        }
        guard silenceThresholdDB < 0 else {
            throw VoxError.config("recording.silence_threshold_db must be negative (dBFS)")
        }
    }
}

public struct OutputConfig: Codable, Sendable, Equatable {
    public enum Destination: String, Codable, Sendable, CaseIterable {
        case clipboard
        case autoPaste
        case stdout
        case json
        case none
    }

    public var destination: Destination
    /// Keep a local session log of transcripts, clearable from the menu bar.
    public var keepSessionHistory: Bool
    /// Oldest entries are dropped past this count. `nil` keeps every entry
    /// forever (useful for building a correction/training dataset later).
    public var sessionHistoryLimit: Int?

    public init(
        destination: Destination = .clipboard,
        keepSessionHistory: Bool = true,
        sessionHistoryLimit: Int? = 50
    ) {
        self.destination = destination
        self.keepSessionHistory = keepSessionHistory
        self.sessionHistoryLimit = sessionHistoryLimit
    }

    public static let `default` = OutputConfig()

    public func validate() throws {
        if let sessionHistoryLimit, sessionHistoryLimit <= 0 {
            throw VoxError.config("output.session_history_limit must be greater than 0 or null")
        }
    }
}

/// `ModeRunner` only ever speaks the OpenAI-compatible protocol; pointing a
/// mode at Ollama versus a remote provider is a LiteLLM routing change.
public struct LLMConfig: Codable, Sendable, Equatable {
    public var baseURL: String
    public var model: String
    /// Environment variable holding the LiteLLM key. Never the key itself: the
    /// config file is plain text and shared with the app.
    public var apiKeyEnvVar: String?
    public var temperature: Double
    public var timeoutSeconds: Double
    /// `nil` (the default) omits `max_tokens` from the request entirely, so
    /// the provider's own default/context-window ceiling applies instead of
    /// an arbitrary cap here. A reasoning model can burn through a small cap
    /// on chain-of-thought alone and never reach its actual answer.
    public var maxOutputTokens: Int?
    /// Opt out of the loopback-only rule for `http://` endpoints, for a
    /// plain-HTTP LiteLLM on a network the user considers trusted. Optional so
    /// configs written before it existed still decode; `nil` means "off".
    public var allowInsecureHTTP: Bool?

    public init(
        baseURL: String = "http://127.0.0.1:4000/v1",
        model: String = "ollama/llama3.1",
        apiKeyEnvVar: String? = "LITELLM_API_KEY",
        temperature: Double = 0.2,
        timeoutSeconds: Double = 60,
        maxOutputTokens: Int? = nil,
        allowInsecureHTTP: Bool? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKeyEnvVar = apiKeyEnvVar
        self.temperature = temperature
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputTokens = maxOutputTokens
        self.allowInsecureHTTP = allowInsecureHTTP
    }

    public static let `default` = LLMConfig()

    /// See `RecordingConfig.CodingKeys` for why the acronym is spelled out.
    enum CodingKeys: String, CodingKey {
        case baseURL = "baseUrl"
        case model
        case apiKeyEnvVar
        case temperature
        case timeoutSeconds
        case maxOutputTokens
        case allowInsecureHTTP = "allowInsecureHttp"
    }

    public var chatCompletionsURL: URL? {
        URL(string: baseURL.hasSuffix("/") ? baseURL + "chat/completions" : baseURL + "/chat/completions")
    }

    /// Rejects an endpoint that would put the transcript — and the
    /// `Authorization: Bearer` header, when `apiKeyEnvVar` is set — on the wire
    /// in cleartext. `http://` is only safe when it never leaves the machine,
    /// so it is allowed for loopback hosts and otherwise requires `https://`
    /// (or an explicit `allowInsecureHTTP` opt-in for a trusted LAN).
    public func validateEndpointSecurity() throws {
        guard let url = URL(string: baseURL), let scheme = url.scheme?.lowercased() else {
            throw VoxError.config("llm.base_url is not a valid URL", detail: baseURL)
        }
        guard scheme == "http" || scheme == "https" else {
            throw VoxError.config(
                "llm.base_url must be an http:// or https:// URL",
                detail: baseURL
            )
        }
        guard scheme == "http", allowInsecureHTTP != true else { return }
        guard !Self.isLoopback(url.host ?? "") else { return }
        let exposed = apiKeyEnvVar.map { "dictated transcripts and the \($0) key" } ?? "dictated transcripts"
        throw VoxError.config(
            "llm.base_url may only use http:// for a loopback host",
            detail: "\(baseURL) would send \(exposed) over the network in cleartext. "
                + "Use https://, or run `vox config set llm.allow_insecure_http true` "
                + "to accept that on a trusted network."
        )
    }

    /// Hosts that cannot leave the machine: `localhost` (and `*.localhost`,
    /// which RFC 6761 reserves for it), the whole `127.0.0.0/8` block, and IPv6
    /// `::1`.
    static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "::1" || host == "[::1]" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return false }
        return octets[0] == "127"
    }
}
