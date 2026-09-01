import Foundation

/// Backs `vox config get/set/list` with a flat, dotted key namespace matching
/// the JSON field names, so the CLI never has to hand-roll parsing per field
/// and the app and CLI agree on what a key means.
public enum ConfigKeys {
    public static let all: [String] = [
        "model",
        "default_mode",
        "language",
        "vocab",
        "hotkey.enabled",
        "hotkey.key_code",
        "hotkey.modifiers",
        "hotkey.activation",
        "recording.max_duration_seconds",
        "recording.silence_timeout_seconds",
        "recording.silence_threshold_db",
        "recording.input_device_uid",
        "output.destination",
        "output.keep_session_history",
        "output.session_history_limit",
        "feedback.sounds_enabled",
        "feedback.start_sound",
        "feedback.stop_sound",
        "feedback.error_sound",
        "feedback.show_overlay",
        "llm.base_url",
        "llm.model",
        "llm.api_key_env_var",
        "llm.temperature",
        "llm.timeout_seconds",
        "llm.max_output_tokens",
    ]

    public static func get(_ key: String, from config: VoxConfig) throws -> String {
        switch key {
        case "model": return config.model
        case "default_mode": return config.defaultMode
        case "language": return config.language ?? "auto"
        case "vocab": return config.vocabulary.joined(separator: ", ")
        case "hotkey.enabled": return String(config.hotkey.enabled)
        case "hotkey.key_code": return String(config.hotkey.keyCode)
        case "hotkey.modifiers": return config.hotkey.modifiers.joined(separator: "+")
        case "hotkey.activation": return config.hotkey.activation.rawValue
        case "recording.max_duration_seconds": return String(config.recording.maxDurationSeconds)
        case "recording.silence_timeout_seconds":
            return config.recording.silenceTimeoutSeconds.map { String($0) } ?? "off"
        case "recording.silence_threshold_db": return String(config.recording.silenceThresholdDB)
        case "recording.input_device_uid": return config.recording.inputDeviceUID ?? "default"
        case "output.destination": return config.output.destination.rawValue
        case "output.keep_session_history": return String(config.output.keepSessionHistory)
        case "output.session_history_limit":
            return config.output.sessionHistoryLimit.map { String($0) } ?? "off"
        case "feedback.sounds_enabled": return String(config.feedback.soundsEnabled)
        case "feedback.start_sound": return config.feedback.startSound ?? "off"
        case "feedback.stop_sound": return config.feedback.stopSound ?? "off"
        case "feedback.error_sound": return config.feedback.errorSound ?? "off"
        case "feedback.show_overlay": return String(config.feedback.showOverlay)
        case "llm.base_url": return config.llm.baseURL
        case "llm.model": return config.llm.model
        case "llm.api_key_env_var": return config.llm.apiKeyEnvVar ?? "none"
        case "llm.temperature": return String(config.llm.temperature)
        case "llm.timeout_seconds": return String(config.llm.timeoutSeconds)
        case "llm.max_output_tokens": return config.llm.maxOutputTokens.map { String($0) } ?? "unset"
        default: throw unknownKey(key)
        }
    }

    /// `auto`, `off`, `none`, `default`, and `unset` clear an optional field —
    /// the same words `get` prints for an absent value, so the output of `get`
    /// can always be fed back into `set`.
    public static func set(_ key: String, to value: String, in config: inout VoxConfig) throws {
        switch key {
        case "model":
            config.model = value
        case "default_mode":
            config.defaultMode = value
        case "language":
            config.language = isUnset(value) ? nil : value
        case "vocab":
            config.vocabulary = VocabInjector.normalize(
                value.split(whereSeparator: { $0 == "," || $0 == "\n" }).map(String.init)
            )
        case "hotkey.enabled":
            config.hotkey.enabled = try bool(value, key)
        case "hotkey.key_code":
            config.hotkey.keyCode = UInt16(try integer(value, key, in: 0...127))
        case "hotkey.modifiers":
            config.hotkey.modifiers = try modifiers(value)
        case "hotkey.activation":
            guard let activation = HotkeyConfig.Activation(rawValue: value) else {
                throw VoxError.config(
                    "Invalid hotkey.activation '\(value)'",
                    detail: "Expected pressAndHold or toggle"
                )
            }
            config.hotkey.activation = activation
        case "recording.max_duration_seconds":
            config.recording.maxDurationSeconds = try number(value, key)
        case "recording.silence_timeout_seconds":
            config.recording.silenceTimeoutSeconds = isUnset(value) ? nil : try number(value, key)
        case "recording.silence_threshold_db":
            config.recording.silenceThresholdDB = try number(value, key)
        case "recording.input_device_uid":
            config.recording.inputDeviceUID = isUnset(value) ? nil : value
        case "output.destination":
            guard let destination = OutputConfig.Destination(rawValue: value) else {
                throw VoxError.config(
                    "Invalid output.destination '\(value)'",
                    detail: "Expected one of: \(OutputConfig.Destination.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            config.output.destination = destination
        case "output.keep_session_history":
            config.output.keepSessionHistory = try bool(value, key)
        case "output.session_history_limit":
            config.output.sessionHistoryLimit = isUnset(value) ? nil : try integer(value, key, in: 1...10_000)
        case "feedback.sounds_enabled":
            config.feedback.soundsEnabled = try bool(value, key)
        case "feedback.start_sound":
            config.feedback.startSound = try soundName(value, key)
        case "feedback.stop_sound":
            config.feedback.stopSound = try soundName(value, key)
        case "feedback.error_sound":
            config.feedback.errorSound = try soundName(value, key)
        case "feedback.show_overlay":
            config.feedback.showOverlay = try bool(value, key)
        case "llm.base_url":
            guard URL(string: value) != nil else {
                throw VoxError.config("llm.base_url is not a valid URL", detail: value)
            }
            config.llm.baseURL = value
        case "llm.model":
            config.llm.model = value
        case "llm.api_key_env_var":
            config.llm.apiKeyEnvVar = isUnset(value) ? nil : value
        case "llm.temperature":
            config.llm.temperature = try number(value, key)
        case "llm.timeout_seconds":
            config.llm.timeoutSeconds = try number(value, key)
        case "llm.max_output_tokens":
            config.llm.maxOutputTokens = isUnset(value) ? nil : try integer(value, key, in: 1...1_000_000)
        default:
            throw unknownKey(key)
        }
        try config.validate()
    }

    static let unsetWords: Set<String> = ["auto", "off", "none", "default", "unset", "null", ""]

    public static func isUnset(_ value: String) -> Bool {
        unsetWords.contains(value.lowercased())
    }

    static func unknownKey(_ key: String) -> VoxError {
        VoxError.config(
            "Unknown config key '\(key)'",
            detail: "Known keys: \(all.joined(separator: ", "))"
        )
    }

    static func bool(_ value: String, _ key: String) throws -> Bool {
        switch value.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: throw VoxError.config("\(key) expects a boolean, got '\(value)'")
        }
    }

    static func number(_ value: String, _ key: String) throws -> Double {
        guard let number = Double(value) else {
            throw VoxError.config("\(key) expects a number, got '\(value)'")
        }
        return number
    }

    static func integer(_ value: String, _ key: String, in range: ClosedRange<Int>) throws -> Int {
        guard let parsed = Int(value), range.contains(parsed) else {
            throw VoxError.config(
                "\(key) expects an integer between \(range.lowerBound) and \(range.upperBound), got '\(value)'"
            )
        }
        return parsed
    }

    /// Typos here would otherwise be silent — a missing sound just does not
    /// play — so the CLI only accepts the stock macOS sounds. Editing the
    /// config file by hand still allows a custom sound from `~/Library/Sounds`.
    static func soundName(_ value: String, _ key: String) throws -> String? {
        if isUnset(value) { return nil }
        guard let match = FeedbackConfig.systemSoundNames.first(
            where: { $0.caseInsensitiveCompare(value) == .orderedSame }
        ) else {
            throw VoxError.config(
                "Unknown sound '\(value)' for \(key)",
                detail: "Expected off or one of: \(FeedbackConfig.systemSoundNames.joined(separator: ", "))"
            )
        }
        return match
    }

    /// Same set the hotkey registration can actually express, so `config set`
    /// cannot accept a modifier that would later be dropped.
    static var knownModifiers: Set<String> { HotkeyConfig.supportedModifiers }

    static func modifiers(_ value: String) throws -> [String] {
        let parts = value
            .split(whereSeparator: { $0 == "+" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        for part in parts where !knownModifiers.contains(part) {
            throw VoxError.config(
                "Unknown modifier '\(part)'",
                detail: "Expected any of: \(knownModifiers.sorted().joined(separator: ", "))"
            )
        }
        return parts
    }
}
