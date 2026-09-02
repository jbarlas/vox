import Foundation

public struct ModeResult: Sendable, Equatable {
    public let text: String
    public let mode: String
    public let kind: ModeDefinition.Kind
    /// The LLM actually used, when the mode was an LLM mode.
    public let llmModel: String?

    public init(text: String, mode: String, kind: ModeDefinition.Kind, llmModel: String? = nil) {
        self.text = text
        self.mode = mode
        self.kind = kind
        self.llmModel = llmModel
    }
}

/// Applies a mode to a finished transcript.
///
/// Runs strictly downstream of transcription: whisper.cpp has no LLM concept,
/// and every LLM call happens here against one OpenAI-compatible endpoint.
public struct ModeRunner: Sendable {
    private let llmConfig: LLMConfig
    private let clientFactory: @Sendable (LLMConfig) throws -> ChatCompletionClient

    public init(
        llmConfig: LLMConfig,
        clientFactory: @escaping @Sendable (LLMConfig) throws -> ChatCompletionClient = {
            try LiteLLMClient(config: $0)
        }
    ) {
        self.llmConfig = llmConfig
        self.clientFactory = clientFactory
    }

    /// `vocabulary` (user terms plus corpus-seeded ones, see
    /// `VocabularyEntry.merge`) is appended to an LLM mode's system prompt as
    /// spelling guidance; raw and cleanup modes ignore it.
    public func run(
        transcript: String,
        mode: ModeDefinition,
        vocabulary: [String] = []
    ) async throws -> ModeResult {
        try mode.validate()
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode.kind {
        case .raw:
            return ModeResult(text: trimmed, mode: mode.name, kind: .raw)
        case .cleanup:
            return ModeResult(text: TextCleanup.clean(trimmed), mode: mode.name, kind: .cleanup)
        case .llm:
            // An empty transcript means the mic captured nothing; spending an
            // LLM round trip on it would only hallucinate content.
            guard !trimmed.isEmpty else {
                return ModeResult(text: "", mode: mode.name, kind: .llm, llmModel: nil)
            }
            // Per-mode endpoint/key/model overrides resolve here, so one mode
            // can run on a hosted provider while the rest stay local.
            let effective = llmConfig.effective(for: mode)
            // Sent as a plain user-role message, a transcript that happens to
            // talk about "the LLM" or "this transcript" reads to a small
            // model as a live message directed at it, not data to edit — it
            // answers instead of editing. Delimiting it heads that off; the
            // built-in prompts below are written to match.
            let request = ChatCompletionRequest(
                model: effective.model,
                systemPrompt: Self.systemPrompt(mode.prompt ?? "", vocabulary: vocabulary),
                userText: "<transcript>\(trimmed)</transcript>",
                temperature: effective.temperature,
                maxOutputTokens: effective.maxOutputTokens
            )
            let client = try clientFactory(effective)
            let completion = try await client.complete(request)
            return ModeResult(
                text: completion.trimmingCharacters(in: .whitespacesAndNewlines),
                mode: mode.name,
                kind: .llm,
                llmModel: effective.model
            )
        }
    }

    /// The system prompt with the vocabulary glossary appended. Kept as an
    /// addendum rather than woven into the mode's own prompt so a custom mode
    /// gets the same guidance without editing it.
    public static func systemPrompt(_ prompt: String, vocabulary: [String]) -> String {
        let terms = VocabInjector.normalize(vocabulary)
        guard !terms.isEmpty else { return prompt }
        let glossary = """
            The speaker often uses these names and terms; when a word in the transcript is a \
            misheard or misspelled version of one, use this spelling: \(terms.joined(separator: ", ")).
            """
        return prompt.isEmpty ? glossary : prompt + "\n\n" + glossary
    }
}
