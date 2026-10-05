import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The HTTP layer under `NotionClient`, injectable so tests never touch the
/// network.
public protocol NotionTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionNotionTransport: NotionTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VoxError.config("Notion returned a non-HTTP response")
        }
        return (data, http)
    }
}

/// A JSON object as Notion returns it. Notion's block and property shapes vary
/// by type, so the export walks them loosely instead of modeling every type.
public typealias NotionObject = [String: Any]

/// Minimal client for the two endpoints vocabulary seeding needs: search (every
/// page shared with the integration) and block children (a page's content).
///
/// Notion allows about three requests per second per integration, so requests
/// are spaced `minimumInterval` apart, a 429 waits out `Retry-After`, and a 5xx
/// is retried with backoff.
public actor NotionClient {
    public static let apiVersion = "2022-06-28"
    public static let defaultBaseURL = URL(string: "https://api.notion.com/v1/")!

    private let token: String
    private let tokenEnvVar: String
    private let baseURL: URL
    private let transport: NotionTransport
    private let minimumInterval: Duration
    private let maxRetries: Int
    private let sleep: @Sendable (Duration) async throws -> Void
    private var lastRequestStarted: ContinuousClock.Instant?
    private(set) var requestCount = 0

    public init(
        token: String,
        tokenEnvVar: String,
        baseURL: URL = NotionClient.defaultBaseURL,
        transport: NotionTransport = URLSessionNotionTransport(),
        minimumInterval: Duration = .milliseconds(340),
        maxRetries: Int = 5,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.token = token
        self.tokenEnvVar = tokenEnvVar
        self.baseURL = baseURL
        self.transport = transport
        self.minimumInterval = minimumInterval
        self.maxRetries = maxRetries
        self.sleep = sleep
    }

    /// One page of search results: pages only, most recently edited first.
    public func searchPages(startCursor: String?) async throws -> (results: [NotionObject], nextCursor: String?) {
        var body: NotionObject = [
            "filter": ["property": "object", "value": "page"],
            "sort": ["direction": "descending", "timestamp": "last_edited_time"],
            "page_size": 100,
        ]
        if let startCursor { body["start_cursor"] = startCursor }
        let json = try await request("POST", path: "search", body: body)
        return Self.page(of: json)
    }

    /// One page of a block's children. `nil` when the block is not visible to
    /// the integration (deleted, or unshared since the search).
    public func blockChildren(of blockID: String, startCursor: String?) async throws -> (
        results: [NotionObject], nextCursor: String?
    )? {
        var path = "blocks/\(blockID)/children?page_size=100"
        if let startCursor {
            path += "&start_cursor=\(startCursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? startCursor)"
        }
        do {
            return Self.page(of: try await request("GET", path: path, body: nil))
        } catch NotionRequestError.notFound {
            return nil
        }
    }

    private static func page(of json: NotionObject) -> (results: [NotionObject], nextCursor: String?) {
        let results = json["results"] as? [NotionObject] ?? []
        let hasMore = json["has_more"] as? Bool ?? false
        return (results, hasMore ? json["next_cursor"] as? String : nil)
    }

    private func request(_ method: String, path: String, body: NotionObject?) async throws -> NotionObject {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw VoxError.config("Invalid Notion request path: \(path)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        var attempt = 0
        while true {
            try await throttle()
            requestCount += 1
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await transport.send(urlRequest)
            } catch let error as VoxError {
                throw error
            } catch {
                throw VoxError.config("Could not reach Notion", detail: error.localizedDescription)
            }

            switch response.statusCode {
            case 200..<300:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? NotionObject else {
                    throw VoxError.config("Notion returned a response that is not a JSON object")
                }
                return json
            case 401:
                throw VoxError.config(
                    "Notion rejected the token in $\(tokenEnvVar)",
                    detail: "Check the integration's secret and that it has not been revoked."
                )
            case 403, 404:
                throw NotionRequestError.notFound
            case 429 where attempt < maxRetries, 500..<600 where attempt < maxRetries:
                attempt += 1
                try await sleep(Self.retryDelay(response: response, attempt: attempt))
            default:
                throw VoxError.config(
                    "Notion request failed with HTTP \(response.statusCode)",
                    detail: Self.message(in: data)
                )
            }
        }
    }

    private func throttle() async throws {
        let clock = ContinuousClock()
        if let lastRequestStarted {
            let wait = lastRequestStarted.advanced(by: minimumInterval) - clock.now
            if wait > .zero { try await sleep(wait) }
        }
        lastRequestStarted = clock.now
    }

    /// `Retry-After` when Notion sends it (429), otherwise exponential backoff.
    static func retryDelay(response: HTTPURLResponse, attempt: Int) -> Duration {
        if let header = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(header), seconds >= 0 {
            return .milliseconds(Int(seconds * 1000))
        }
        return .seconds(min(1 << (attempt - 1), 30))
    }

    private static func message(in data: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: data) as? NotionObject
        return json?["message"] as? String
    }
}

enum NotionRequestError: Error {
    case notFound
}
