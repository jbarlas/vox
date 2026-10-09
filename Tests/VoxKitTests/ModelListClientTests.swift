import XCTest

@testable import VoxKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Serves canned responses so the client can be exercised without a live
/// Ollama. Requests are recorded for header/URL assertions.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class ModelListClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
        super.tearDown()
    }

    private func ok(_ body: String) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
    }

    // MARK: shouldQuery

    func testOnlyLoopbackEndpointsAreQueried() {
        XCTAssertTrue(ModelListClient.shouldQuery(LLMConfig(baseURL: LLMProviderCatalog.ollama.baseURL)))
        // LiteLLM names a key variable and is still local.
        XCTAssertTrue(ModelListClient.shouldQuery(LLMConfig(baseURL: LLMProviderCatalog.litellm.baseURL)))
        XCTAssertTrue(ModelListClient.shouldQuery(LLMConfig(baseURL: "http://localhost:8080/v1")))
        XCTAssertTrue(ModelListClient.shouldQuery(LLMConfig(baseURL: "https://[::1]:8080/v1")))

        for hosted in [LLMProviderCatalog.openAI, LLMProviderCatalog.anthropic, LLMProviderCatalog.groq] {
            XCTAssertFalse(ModelListClient.shouldQuery(LLMConfig(baseURL: hosted.baseURL)), hosted.id)
        }
        XCTAssertFalse(ModelListClient.shouldQuery(LLMConfig(baseURL: "http://192.168.1.10:4000/v1")))
        XCTAssertFalse(ModelListClient.shouldQuery(LLMConfig(baseURL: "not a url")))
        XCTAssertFalse(ModelListClient.shouldQuery(LLMConfig(baseURL: "")))
    }

    // MARK: URL and headers

    func testModelsURLAppendsToBaseWithOrWithoutTrailingSlash() {
        XCTAssertEqual(
            LLMConfig(baseURL: "http://127.0.0.1:11434/v1").modelsURL?.absoluteString,
            "http://127.0.0.1:11434/v1/models"
        )
        XCTAssertEqual(
            LLMConfig(baseURL: "http://127.0.0.1:11434/v1/").modelsURL?.absoluteString,
            "http://127.0.0.1:11434/v1/models"
        )
    }

    func testRequestIsAGetWithoutAuthorizationWhenNoKeyIsConfigured() async throws {
        StubURLProtocol.handler = ok(#"{"object":"list","data":[]}"#)
        let config = LLMConfig(baseURL: LLMProviderCatalog.ollama.baseURL, apiKeyEnvVar: nil)
        let client = try ModelListClient(config: config, environment: [:], session: session)
        _ = try await client.listModels()

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/v1/models")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testRequestSendsBearerWhenTheKeyVariableIsSet() async throws {
        StubURLProtocol.handler = ok(#"{"object":"list","data":[]}"#)
        let config = LLMConfig(baseURL: LLMProviderCatalog.litellm.baseURL, apiKeyEnvVar: "LITELLM_API_KEY")
        let client = try ModelListClient(
            config: config, environment: ["LITELLM_API_KEY": "sk-test"], session: session)
        _ = try await client.listModels()

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testMissingOrEmptyKeyIsNotAnError() async throws {
        StubURLProtocol.handler = ok(#"{"object":"list","data":[]}"#)
        let config = LLMConfig(baseURL: LLMProviderCatalog.litellm.baseURL, apiKeyEnvVar: "LITELLM_API_KEY")
        let client = try ModelListClient(config: config, environment: ["LITELLM_API_KEY": ""], session: session)
        _ = try await client.listModels()
        XCTAssertNil(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: Decoding

    func testDecodesOllamaShapedListInOrder() async throws {
        StubURLProtocol.handler = ok(
            """
            {"object":"list","data":[
              {"id":"phi4-mini:3.8b-q8_0","object":"model","created":1,"owned_by":"library"},
              {"id":"qwen3.6:27b-q8_0","object":"model","created":2,"owned_by":"library"},
              {"id":"gemma4:26b","object":"model","created":3,"owned_by":"library"}
            ]}
            """)
        let client = try ModelListClient(
            config: LLMConfig(baseURL: LLMProviderCatalog.ollama.baseURL), environment: [:], session: session)
        let models = try await client.listModels()
        XCTAssertEqual(models, ["phi4-mini:3.8b-q8_0", "qwen3.6:27b-q8_0", "gemma4:26b"])
    }

    func testDecodingSkipsBlankAndDuplicateIDs() throws {
        let data = Data(#"{"data":[{"id":"a"},{"id":""},{"object":"model"},{"id":"a"},{"id":"b"}]}"#.utf8)
        XCTAssertEqual(try ModelListClient.modelIDs(fromResponse: data), ["a", "b"])
    }

    func testEmptyListIsNotAnError() throws {
        XCTAssertEqual(try ModelListClient.modelIDs(fromResponse: Data(#"{"data":[]}"#.utf8)), [])
    }

    func testNonListJSONIsAnLLMError() {
        for body in ["not json", "{}", #"{"models":["a"]}"#, "[]"] {
            XCTAssertThrowsError(try ModelListClient.modelIDs(fromResponse: Data(body.utf8)), body) { error in
                XCTAssertEqual((error as? VoxError)?.code, .llm)
            }
        }
    }

    // MARK: Rows

    func testActiveModelIsAppendedOnlyWhenMissing() {
        XCTAssertEqual(ModelListSource.rows(models: ["a", "b"], active: "b"), ["a", "b"])
        XCTAssertEqual(ModelListSource.rows(models: ["a", "b"], active: "gemma4:26b"), ["a", "b", "gemma4:26b"])
        XCTAssertEqual(ModelListSource.rows(models: ["a"], active: "  "), ["a"])
        XCTAssertEqual(ModelListSource.rows(models: [], active: "x"), ["x"])
    }

    // MARK: Failure modes the UI falls back on

    func testUnimplementedEndpointIsAnLLMError() async throws {
        StubURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data("not found".utf8)
            )
        }
        let client = try ModelListClient(
            config: LLMConfig(baseURL: LLMProviderCatalog.ollama.baseURL), environment: [:], session: session)
        do {
            _ = try await client.listModels()
            XCTFail("expected an error")
        } catch let error as VoxError {
            XCTAssertEqual(error.code, .llm)
            XCTAssertTrue(error.message.contains("404"), error.message)
        }
    }

    func testUnreachableEndpointIsAnLLMError() async throws {
        StubURLProtocol.handler = nil  // the stub fails with cannotConnectToHost
        let client = try ModelListClient(
            config: LLMConfig(baseURL: LLMProviderCatalog.ollama.baseURL), environment: [:], session: session)
        do {
            _ = try await client.listModels()
            XCTFail("expected an error")
        } catch let error as VoxError {
            XCTAssertEqual(error.code, .llm)
        }
    }
}
