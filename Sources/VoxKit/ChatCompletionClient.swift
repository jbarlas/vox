import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ChatCompletionRequest: Sendable, Equatable {
    public var model: String
    public var systemPrompt: String
    public var userText: String
    public var temperature: Double
    public var maxOutputTokens: Int?

    public init(
        model: String,
        systemPrompt: String,
        userText: String,
        temperature: Double,
        maxOutputTokens: Int?
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.userText = userText
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
    }
}

/// The single protocol `ModeRunner` speaks. Swapping a mode between a local
/// Ollama model and a remote provider is a LiteLLM routing change, not a change
/// here.
public protocol ChatCompletionClient: Sendable {
    func complete(_ request: ChatCompletionRequest) async throws -> String
}

/// OpenAI-compatible chat-completions client, pointed at a local LiteLLM proxy
/// by default.
public struct LiteLLMClient: ChatCompletionClient {
    private let endpoint: URL
    private let apiKey: String?
    private let timeout: TimeInterval
    private let session: URLSession

    public init(config: LLMConfig, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        // Checked here as well as in `vox config set`: a hand-edited
        // config.json must not be a way to POST transcripts in cleartext, and
        // failing at construction keeps the request from ever being sent (a
        // mode failure degrades to the raw transcript rather than losing it).
        try config.validateEndpointSecurity()
        guard let endpoint = config.chatCompletionsURL else {
            throw VoxError.llm("llm.base_url is not a valid URL", detail: config.baseURL)
        }
        self.endpoint = endpoint
        self.apiKey = config.apiKeyEnvVar.flatMap { environment[$0] }.flatMap { $0.isEmpty ? nil : $0 }
        self.timeout = config.timeoutSeconds
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = config.timeoutSeconds
        self.session = URLSession(configuration: sessionConfiguration)
    }

    public func complete(_ request: ChatCompletionRequest) async throws -> String {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try Self.body(for: request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw VoxError.llm(
                "LLM endpoint at \(endpoint.absoluteString) didn't respond within \(Int(timeout))s",
                detail: "A local model that has to load from disk first can easily take longer than "
                    + "that on the first call after it goes idle. Raise llm.timeout_seconds, or keep "
                    + "the model warm (e.g. Ollama's keep_alive)."
            )
        } catch {
            throw VoxError.llm(
                "Could not reach the LLM endpoint at \(endpoint.absoluteString)",
                detail: "\(error.localizedDescription) — is the endpoint running?"
            )
        }
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw VoxError.llm(
                "LLM endpoint returned HTTP \(httpResponse.statusCode)",
                detail: String(data: data, encoding: .utf8)
            )
        }
        return try Self.text(fromResponse: data)
    }

    static func body(for request: ChatCompletionRequest) throws -> Data {
        var payload: [String: Any] = [
            "model": request.model,
            "temperature": request.temperature,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.userText],
            ],
        ]
        if let maxOutputTokens = request.maxOutputTokens {
            payload["max_tokens"] = maxOutputTokens
        }
        do {
            return try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw VoxError.llm("Could not encode the LLM request", detail: String(describing: error))
        }
    }

    static func text(fromResponse data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message?
            }
            let choices: [Choice]?
        }
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw VoxError.llm(
                "LLM response was not valid chat-completions JSON",
                detail: String(data: data, encoding: .utf8)
            )
        }
        guard let content = decoded.choices?.first?.message?.content, !content.isEmpty else {
            throw VoxError.llm(
                "LLM response contained no message content",
                detail: String(data: data, encoding: .utf8)
            )
        }
        return content
    }
}
