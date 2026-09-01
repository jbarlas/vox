import XCTest

@testable import VoxKit

private final class RecordingClient: ChatCompletionClient, @unchecked Sendable {
    var lastRequest: ChatCompletionRequest?
    var response: String = "cleaned up"
    var error: Error?

    func complete(_ request: ChatCompletionRequest) async throws -> String {
        lastRequest = request
        if let error { throw error }
        return response
    }
}

final class ModeRunnerTests: XCTestCase {
    private func runner(client: RecordingClient, llm: LLMConfig = .default) -> ModeRunner {
        ModeRunner(llmConfig: llm, clientFactory: { _ in client })
    }

    func testRawModeTrimsButDoesNotAlterText() async throws {
        let client = RecordingClient()
        let result = try await runner(client: client)
            .run(transcript: "  um check the logs  ", mode: .raw)
        XCTAssertEqual(result.text, "um check the logs")
        XCTAssertNil(client.lastRequest, "raw mode must never call the LLM")
    }

    func testCleanupModeAppliesLocalRulesWithoutTheLLM() async throws {
        let client = RecordingClient()
        let result = try await runner(client: client)
            .run(transcript: "um check the logs", mode: .cleanup)
        XCTAssertEqual(result.text, "Check the logs")
        XCTAssertNil(client.lastRequest)
    }

    func testLLMModeSendsPromptAndConfiguredModel() async throws {
        let client = RecordingClient()
        client.response = "Check the deploy logs for errors."
        let result = try await runner(client: client)
            .run(transcript: "uh check deploy logs", mode: .instructionPrompt)

        let request = try XCTUnwrap(client.lastRequest)
        XCTAssertEqual(request.model, LLMConfig.default.model)
        XCTAssertEqual(request.userText, "<transcript>uh check deploy logs</transcript>")
        XCTAssertEqual(request.systemPrompt, ModeDefinition.instructionPrompt.prompt)
        XCTAssertEqual(request.temperature, LLMConfig.default.temperature)
        XCTAssertEqual(result.text, "Check the deploy logs for errors.")
        XCTAssertEqual(result.llmModel, LLMConfig.default.model)
    }

    func testModeOverridesModelAndTemperature() async throws {
        let client = RecordingClient()
        let mode = ModeDefinition(
            name: "remote",
            kind: .llm,
            prompt: "Rewrite.",
            model: "openai/gpt-4o-mini",
            temperature: 0.9
        )
        let result = try await runner(client: client).run(transcript: "hello", mode: mode)

        let request = try XCTUnwrap(client.lastRequest)
        XCTAssertEqual(request.model, "openai/gpt-4o-mini")
        XCTAssertEqual(request.temperature, 0.9)
        XCTAssertEqual(result.llmModel, "openai/gpt-4o-mini")
    }

    func testEmptyTranscriptSkipsTheLLMEntirely() async throws {
        let client = RecordingClient()
        let result = try await runner(client: client).run(transcript: "   ", mode: .instructionPrompt)
        XCTAssertEqual(result.text, "")
        XCTAssertNil(client.lastRequest)
    }

    func testLLMFailureSurfacesAsAnLLMError() async {
        let client = RecordingClient()
        client.error = VoxError.llm("connection refused")
        do {
            _ = try await runner(client: client).run(transcript: "hello", mode: .instructionPrompt)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? VoxError)?.code, .llm)
        }
    }

    func testChatCompletionsURLIsBuiltFromBaseURL() {
        XCTAssertEqual(
            LLMConfig(baseURL: "http://127.0.0.1:4000/v1").chatCompletionsURL?.absoluteString,
            "http://127.0.0.1:4000/v1/chat/completions"
        )
        XCTAssertEqual(
            LLMConfig(baseURL: "http://127.0.0.1:4000/v1/").chatCompletionsURL?.absoluteString,
            "http://127.0.0.1:4000/v1/chat/completions"
        )
    }

    func testRequestBodyMatchesTheOpenAIChatShape() throws {
        let request = ChatCompletionRequest(
            model: "ollama/llama3.1",
            systemPrompt: "Be terse.",
            userText: "hello",
            temperature: 0.2,
            maxOutputTokens: 64
        )
        let json = try JSONSerialization.jsonObject(with: try LiteLLMClient.body(for: request))
        let payload = try XCTUnwrap(json as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "ollama/llama3.1")
        XCTAssertEqual(payload["max_tokens"] as? Int, 64)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages.last?["content"], "hello")
    }

    func testResponseParsingAndFailureModes() throws {
        let valid = Data(#"{"choices":[{"message":{"content":"done"}}]}"#.utf8)
        XCTAssertEqual(try LiteLLMClient.text(fromResponse: valid), "done")

        XCTAssertThrowsError(try LiteLLMClient.text(fromResponse: Data(#"{"choices":[]}"#.utf8)))
        XCTAssertThrowsError(try LiteLLMClient.text(fromResponse: Data("not json".utf8)))
    }
}
