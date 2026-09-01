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

    public func run(transcript: String, mode: ModeDefinition) async throws -> ModeResult {
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
            let model = mode.model ?? llmConfig.model
            // Sent as a plain user-role message, a transcript that happens to
            // talk about "the LLM" or "this transcript" reads to a small
            // model as a live message directed at it, not data to edit — it
            // answers instead of editing. Delimiting it heads that off; the
            // built-in prompts below are written to match.
            let request = ChatCompletionRequest(
                model: model,
                systemPrompt: mode.prompt ?? "",
                userText: "<transcript>\(trimmed)</transcript>",
                temperature: mode.temperature ?? llmConfig.temperature,
                maxOutputTokens: llmConfig.maxOutputTokens
            )
            let client = try clientFactory(llmConfig)
            let completion = try await client.complete(request)
            return ModeResult(
                text: completion.trimmingCharacters(in: .whitespacesAndNewlines),
                mode: mode.name,
                kind: .llm,
                llmModel: model
            )
        }
    }
}
