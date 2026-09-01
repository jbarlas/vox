import XCTest

@testable import VoxKit

/// Provider presets and the per-mode overrides they feed, which decide where a
/// single dictation's transcript actually gets sent.
final class LLMProviderTests: XCTestCase {
    func testProviderLookupIsCaseInsensitiveAndIgnoresTrailingSlashes() {
        XCTAssertEqual(LLMProviderCatalog.provider(id: "OpenAI")?.id, "openai")
        XCTAssertNil(LLMProviderCatalog.provider(id: "azure"))
        XCTAssertEqual(
            LLMProviderCatalog.provider(forBaseURL: "https://api.groq.com/openai/v1/")?.id,
            "groq"
        )
        XCTAssertNil(LLMProviderCatalog.provider(forBaseURL: "https://llm.example.com/v1"))
    }

    /// Every preset has to be usable as-is: an endpoint Vox would then refuse
    /// to call, or a key variable that isn't the one the provider documents,
    /// makes the preset worse than typing the URL.
    func testPresetsAreUsableAsConfigured() throws {
        for provider in LLMProviderCatalog.all {
            var config = LLMConfig()
            config.apply(provider)
            XCTAssertEqual(config.baseURL, provider.baseURL)
            XCTAssertEqual(config.apiKeyEnvVar, provider.apiKeyEnvVar)
            XCTAssertNoThrow(try config.validateEndpointSecurity(), provider.id)
            XCTAssertNotNil(config.chatCompletionsURL, provider.id)
            XCTAssertFalse(provider.exampleModels.isEmpty, provider.id)
        }
    }

    func testApplyingAProviderLeavesTheModelAlone() {
        var config = LLMConfig(model: "ollama/llama3.1")
        config.apply(LLMProviderCatalog.openAI)
        XCTAssertEqual(config.model, "ollama/llama3.1")
    }

    func testModeInheritsGlobalEndpointWithoutOverrides() {
        let config = LLMConfig(baseURL: "http://127.0.0.1:4000/v1", apiKeyEnvVar: "LITELLM_API_KEY")
        let effective = config.effective(for: ModeDefinition(name: "prompt", kind: .llm, prompt: "p"))
        XCTAssertEqual(effective, config)
    }

    func testModeOverridesEndpointModelAndKey() {
        let config = LLMConfig(model: "ollama/llama3.1", apiKeyEnvVar: "LITELLM_API_KEY")
        let mode = ModeDefinition(
            name: "email",
            kind: .llm,
            prompt: "p",
            model: "gpt-4o-mini",
            baseURL: "https://api.openai.com/v1",
            apiKeyEnvVar: "OPENAI_API_KEY",
            temperature: 0.7
        )
        let effective = config.effective(for: mode)
        XCTAssertEqual(effective.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(effective.model, "gpt-4o-mini")
        XCTAssertEqual(effective.apiKeyEnvVar, "OPENAI_API_KEY")
        XCTAssertEqual(effective.temperature, 0.7)
        // Not overridable per mode, so they still come from the global config.
        XCTAssertEqual(effective.timeoutSeconds, config.timeoutSeconds)
    }

    /// The global key was chosen for the global endpoint; forwarding it would
    /// hand a local proxy's key to whatever host one mode was pointed at.
    func testEndpointOverrideWithoutItsOwnKeySendsNone() {
        let config = LLMConfig(apiKeyEnvVar: "LITELLM_API_KEY")
        let mode = ModeDefinition(
            name: "email",
            kind: .llm,
            prompt: "p",
            baseURL: "https://api.openai.com/v1"
        )
        XCTAssertNil(config.effective(for: mode).apiKeyEnvVar)
    }

    /// Same reasoning for the trusted-LAN opt-in: it was granted for one host.
    func testEndpointOverrideDoesNotInheritInsecureHTTPOptIn() {
        var config = LLMConfig(baseURL: "http://192.168.1.10:4000/v1")
        config.allowInsecureHTTP = true
        let mode = ModeDefinition(
            name: "email",
            kind: .llm,
            prompt: "p",
            baseURL: "http://llm.example.com/v1"
        )
        XCTAssertThrowsError(try config.effective(for: mode).validateEndpointSecurity())
    }

    func testKeyOverrideAloneKeepsTheGlobalEndpoint() {
        let config = LLMConfig(apiKeyEnvVar: "LITELLM_API_KEY")
        let mode = ModeDefinition(name: "email", kind: .llm, prompt: "p", apiKeyEnvVar: "OTHER_KEY")
        let effective = config.effective(for: mode)
        XCTAssertEqual(effective.baseURL, config.baseURL)
        XCTAssertEqual(effective.apiKeyEnvVar, "OTHER_KEY")
    }

    /// A mode's endpoint field must not be a way around the cleartext rule the
    /// global endpoint is held to.
    func testConfigRejectsCleartextModeEndpoint() {
        var config = VoxConfig()
        XCTAssertThrowsError(
            try config.setMode(
                ModeDefinition(
                    name: "leaky",
                    kind: .llm,
                    prompt: "p",
                    baseURL: "http://llm.example.com/v1"
                )
            )
        ) { error in
            XCTAssertEqual((error as? VoxError)?.code, .config)
            XCTAssertTrue((error as? VoxError)?.message.contains("leaky") == true)
        }
    }

    func testNonLLMModeCannotOverrideAnEndpoint() {
        var config = VoxConfig()
        XCTAssertThrowsError(
            try config.setMode(
                ModeDefinition(name: "raw", kind: .raw, baseURL: "https://api.openai.com/v1")
            )
        )
    }

    /// `config.json` predates these fields, so a mode without them has to keep
    /// decoding — and a mode with them has to survive a round trip.
    func testJSONCompatibility() throws {
        let old = #"{"name":"email","kind":"llm","prompt":"p","model":"gpt-4o-mini"}"#
        let decoder = VoxJSON.decoder()
        let decoded = try decoder.decode(ModeDefinition.self, from: Data(old.utf8))
        XCTAssertNil(decoded.baseURL)
        XCTAssertNil(decoded.apiKeyEnvVar)

        var mode = decoded
        mode.baseURL = "https://api.openai.com/v1"
        mode.apiKeyEnvVar = "OPENAI_API_KEY"
        let encoded = try VoxJSON.string(mode)
        XCTAssertTrue(encoded.contains("\"base_url\""), encoded)
        XCTAssertEqual(try decoder.decode(ModeDefinition.self, from: Data(encoded.utf8)), mode)
    }

    /// The key only ever lives in the environment — a provider preset must not
    /// be a path to writing one into the config file.
    func testConfigNeverPersistsAKeyValue() throws {
        var config = VoxConfig()
        config.llm.apply(LLMProviderCatalog.openAI)
        let json = try VoxJSON.string(config)
        XCTAssertTrue(json.contains("OPENAI_API_KEY"))
        XCTAssertFalse(json.lowercased().contains("\"api_key\""), json)
    }

    /// A hosted endpoint with no key reaching it fails as an opaque 401, so the
    /// client refuses to be built instead.
    func testClientRequiresTheKeyToBePresentForARemoteEndpoint() {
        var config = LLMConfig()
        config.apply(LLMProviderCatalog.openAI)
        XCTAssertThrowsError(try LiteLLMClient(config: config, environment: [:])) { error in
            XCTAssertTrue((error as? VoxError)?.message.contains("OPENAI_API_KEY") == true)
        }
        XCTAssertNoThrow(try LiteLLMClient(config: config, environment: ["OPENAI_API_KEY": "k"]))
    }

    /// The local defaults accept a keyless request, so a missing variable there
    /// is a working setup rather than an error.
    func testLocalEndpointToleratesAMissingKey() {
        XCTAssertNoThrow(try LiteLLMClient(config: LLMConfig(), environment: [:]))
    }
}
