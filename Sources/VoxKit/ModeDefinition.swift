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

    public static let agentPrompt = ModeDefinition(
        name: "prompt",
        kind: .llm,
        description: "Rewrites spoken rambling into a clear instruction for a coding agent.",
        prompt: """
            You rewrite dictated speech into a single clear instruction for a coding agent.
            Preserve every technical detail, file path, and identifier exactly as spoken.
            Remove filler, false starts, and self-corrections; keep only the final intent.
            Output only the rewritten instruction, with no preamble, quotes, or commentary.
            """
    )

    public static let email = ModeDefinition(
        name: "email",
        kind: .llm,
        description: "Turns dictation into a concise, professional message.",
        prompt: """
            Rewrite the dictated text as a concise, professional message.
            Keep the author's intent and any specifics; do not invent details.
            Output only the message body, with no subject line or commentary.
            """
    )

    /// Shipped in a freshly initialized config so both the CLI and the app have
    /// something useful on first run.
    public static let builtIns: [ModeDefinition] = [.raw, .cleanup, .agentPrompt, .email]
}
