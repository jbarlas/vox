import Foundation

/// A known OpenAI-compatible chat-completions endpoint, so picking "OpenAI" or
/// "Groq" is one choice instead of a base URL plus an environment-variable name
/// the user has to look up.
///
/// Vox still only speaks the OpenAI chat-completions protocol — a provider here
/// is a preset for `LLMConfig`/`ModeDefinition` fields, not a second code path.
/// Anything not listed is still configurable by setting the fields directly.
public struct LLMProvider: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    /// Includes the `/v1` (or equivalent) prefix; `chat/completions` is
    /// appended by `LLMConfig.chatCompletionsURL`.
    public let baseURL: String
    /// The variable name each provider's own documentation uses. `nil` for
    /// endpoints that take no key.
    public let apiKeyEnvVar: String?
    /// Illustrative model ids for the endpoint, shown as placeholder text.
    /// Deliberately not validated: provider catalogs change far faster than
    /// Vox releases, and a stale allowlist would reject working models.
    public let exampleModels: [String]
    public let note: String?

    public init(
        id: String,
        displayName: String,
        baseURL: String,
        apiKeyEnvVar: String?,
        exampleModels: [String],
        note: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKeyEnvVar = apiKeyEnvVar
        self.exampleModels = exampleModels
        self.note = note
    }
}

public enum LLMProviderCatalog {
    public static let litellm = LLMProvider(
        id: "litellm",
        displayName: "LiteLLM proxy (local)",
        baseURL: "http://127.0.0.1:4000/v1",
        apiKeyEnvVar: "LITELLM_API_KEY",
        exampleModels: ["ollama/llama3.1", "openai/gpt-4o-mini"],
        note: "Routes to whatever your proxy config declares, local or hosted."
    )

    public static let ollama = LLMProvider(
        id: "ollama",
        displayName: "Ollama (local)",
        baseURL: "http://127.0.0.1:11434/v1",
        apiKeyEnvVar: nil,
        exampleModels: ["llama3.1", "qwen2.5"],
        note: "Ollama's own OpenAI-compatible endpoint. Nothing leaves the machine."
    )

    public static let openAI = LLMProvider(
        id: "openai",
        displayName: "OpenAI",
        baseURL: "https://api.openai.com/v1",
        apiKeyEnvVar: "OPENAI_API_KEY",
        exampleModels: ["gpt-4o-mini", "gpt-4o"]
    )

    public static let anthropic = LLMProvider(
        id: "anthropic",
        displayName: "Anthropic",
        baseURL: "https://api.anthropic.com/v1",
        apiKeyEnvVar: "ANTHROPIC_API_KEY",
        exampleModels: ["claude-sonnet-4-5", "claude-haiku-4-5"],
        note: "Anthropic's OpenAI SDK compatibility layer, which its docs "
            + "position as a testing path rather than the full native API."
    )

    public static let groq = LLMProvider(
        id: "groq",
        displayName: "Groq",
        baseURL: "https://api.groq.com/openai/v1",
        apiKeyEnvVar: "GROQ_API_KEY",
        exampleModels: ["llama-3.3-70b-versatile", "openai/gpt-oss-120b"]
    )

    public static let all: [LLMProvider] = [litellm, ollama, openAI, anthropic, groq]

    public static func provider(id: String) -> LLMProvider? {
        all.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// The provider a base URL belongs to, or `nil` for a hand-configured
    /// endpoint. Compared host-and-path-wise so a trailing slash still matches.
    public static func provider(forBaseURL baseURL: String) -> LLMProvider? {
        let normalized = normalize(baseURL)
        return all.first { normalize($0.baseURL) == normalized }
    }

    static func normalize(_ baseURL: String) -> String {
        var trimmed = baseURL.trimmingCharacters(in: .whitespaces).lowercased()
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}
