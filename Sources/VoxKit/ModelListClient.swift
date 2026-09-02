import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What Settings has to show for an endpoint's model list: either what the
/// endpoint itself reports, or the catalog's illustrative examples.
public enum ModelListSource: Sendable, Equatable {
    /// Ids returned by `GET {baseURL}/models`.
    case installed
    /// The provider's static `exampleModels`, because the endpoint was not
    /// probed, was unreachable, or does not implement `/models`.
    case examples
}

/// Reads the OpenAI-compatible `GET {baseURL}/models` listing that Ollama,
/// LiteLLM, and most local OpenAI-compatible servers expose alongside
/// `chat/completions`.
///
/// Only meant for endpoints that never leave the machine (`shouldQuery`): a
/// hosted provider would need a live API key round-trip just to render
/// Settings, and its catalog changes far slower than a local pull anyway.
public struct ModelListClient: Sendable {
    private let endpoint: URL
    private let apiKey: String?
    private let timeout: TimeInterval
    private let session: URLSession

    /// Whether the endpoint is worth probing: an `http(s)://` URL on a
    /// loopback host. Whether a key variable is configured is deliberately not
    /// part of the rule — a local LiteLLM proxy names one and is still local.
    public static func shouldQuery(_ config: LLMConfig) -> Bool {
        guard let url = URL(string: config.baseURL), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return false }
        return LLMConfig.isLoopback(url.host ?? "")
    }

    /// `timeout` is short by default: this runs while Settings is open, and a
    /// down endpoint should fall back to the examples quickly rather than wait
    /// out the dictation-sized `llm.timeout_seconds`.
    public init(
        config: LLMConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 3,
        session: URLSession = .shared
    ) throws {
        guard let endpoint = config.modelsURL else {
            throw VoxError.llm("llm.base_url is not a valid URL", detail: config.baseURL)
        }
        self.endpoint = endpoint
        // Sent when present (a LiteLLM proxy with a master key gates `/models`
        // too) but never required: Ollama takes none.
        self.apiKey = config.apiKeyEnvVar.flatMap { environment[$0] }.flatMap { $0.isEmpty ? nil : $0 }
        self.timeout = timeout
        self.session = session
    }

    /// The model ids the endpoint serves, in the order it reports them.
    /// Throws `VoxError.llm` when the endpoint is unreachable, answers with a
    /// non-2xx status (e.g. a server without `/models`), or returns something
    /// other than a `{"data":[{"id":…}]}` list.
    public func listModels() async throws -> [String] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw VoxError.llm(
                "Could not reach \(endpoint.absoluteString)",
                detail: "\(error.localizedDescription) — is the endpoint running?"
            )
        }
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw VoxError.llm(
                "\(endpoint.absoluteString) returned HTTP \(httpResponse.statusCode)",
                detail: String(data: data, encoding: .utf8)
            )
        }
        return try Self.modelIDs(fromResponse: data)
    }

    static func modelIDs(fromResponse data: Data) throws -> [String] {
        struct Response: Decodable {
            struct Model: Decodable { let id: String? }
            let data: [Model]?
        }
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw VoxError.llm(
                "Model list was not valid OpenAI-compatible JSON",
                detail: String(data: data, encoding: .utf8)
            )
        }
        guard let models = decoded.data else {
            throw VoxError.llm(
                "Model list contained no `data` array",
                detail: String(data: data, encoding: .utf8)
            )
        }
        var seen = Set<String>()
        return models.compactMap { model in
            guard let id = model.id, !id.isEmpty, seen.insert(id).inserted else { return nil }
            return id
        }
    }
}

extension ModelListSource {
    /// The rows a model picker shows: `models`, plus the configured `active`
    /// model appended when the list doesn't already contain it — so the model
    /// dictation actually uses is always visible, even when the endpoint
    /// didn't report it or the list is only examples.
    public static func rows(models: [String], active: String) -> [String] {
        let active = active.trimmingCharacters(in: .whitespaces)
        guard !active.isEmpty, !models.contains(active) else { return models }
        return models + [active]
    }
}

extension LLMConfig {
    /// `GET` here lists the endpoint's models; sibling of `chatCompletionsURL`.
    public var modelsURL: URL? {
        URL(string: baseURL.hasSuffix("/") ? baseURL + "models" : baseURL + "/models")
    }
}
