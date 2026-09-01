import Foundation

/// A named post-processing step applied to a transcript.
///
/// Adding a mode — or repointing one from a local to a remote model — is a
/// config edit, never a code change.
public struct ModeDefinition: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// whisper.cpp output, untouched.
        case raw
        /// Deterministic filler-word and punctuation cleanup. No LLM.
        case cleanup
        /// Transcript plus a prompt, sent to the configured LiteLLM endpoint.
        case llm
    }

    public var name: String
    public var kind: Kind
    public var description: String?
    /// Required for `.llm`; used as the system prompt.
    public var prompt: String?
    /// Overrides `LLMConfig.model` for this mode only.
    public var model: String?
    public var temperature: Double?

    public init(
        name: String,
        kind: Kind,
        description: String? = nil,
        prompt: String? = nil,
        model: String? = nil,
        temperature: Double? = nil
    ) {
        self.name = name
        self.kind = kind
        self.description = description
        self.prompt = prompt
        self.model = model
        self.temperature = temperature
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw VoxError.config("Mode names cannot be empty")
        }
        if kind == .llm {
            guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoxError.config("Mode '\(name)' is an llm mode but has no prompt")
            }
        }
    }

    public static let raw = ModeDefinition(
        name: "raw",
        kind: .raw,
        description: "Untouched transcription output."
    )

    public static let cleanup = ModeDefinition(
        name: "cleanup",
        kind: .cleanup,
        description: "Removes filler words and tidies spacing/punctuation. Fully local, no LLM."
    )

    public static let instructionPrompt = ModeDefinition(
        name: "prompt",
        kind: .llm,
        description: "Lightly cleans up dictated speech into a clear written instruction, changing as little as possible.",
        prompt: """
            You turn dictated speech into a clear written instruction — for a person or an \
            agent of any kind, coding or otherwise. Make the smallest edit that works: \
            remove filler words, false starts, and stutters, and fix disfluent grammar, but \
            otherwise keep the speaker's own wording, phrasing, and order. Preserve every \
            specific detail exactly as spoken — names, numbers, file paths, identifiers, and \
            technical terms — and do not summarize, condense, or drop anything the speaker \
            said on purpose.
            Output only the rewritten instruction, with no preamble, quotes, or commentary.
            """
    )

    public static let email = ModeDefinition(
        name: "email",
        kind: .llm,
        description: "Tidies dictation into a professional-sounding message, changing as little as possible.",
        prompt: """
            You turn dictated speech into a written message with a professional tone. Make \
            the smallest edit that works: remove filler words, false starts, and stutters, \
            and smooth disfluent grammar, but otherwise keep the speaker's own wording, \
            structure, and every specific detail — names, numbers, dates, and facts — \
            exactly as spoken. Do not summarize, condense, or invent anything the speaker \
            did not say, including a greeting or sign-off the speaker didn't dictate — add \
            one only if the speaker actually opened or closed with one.
            Output only the message body, with no subject line or commentary.
            """
    )

    /// Shipped in a freshly initialized config so both the CLI and the app have
    /// something useful on first run.
    public static let builtIns: [ModeDefinition] = [.raw, .cleanup, .instructionPrompt, .email]
}
