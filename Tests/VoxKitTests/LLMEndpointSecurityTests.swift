import XCTest

@testable import VoxKit

/// `vox config set` is not the only way an endpoint gets into the config —
/// `config.json` is hand-editable — so the client refuses to be built at all
/// for one that would put transcripts on the wire in cleartext.
final class LLMEndpointSecurityTests: XCTestCase {
    func testClientRefusesCleartextNonLoopbackEndpoint() {
        var config = LLMConfig()
        config.baseURL = "http://litellm.internal/v1"
        XCTAssertThrowsError(try LiteLLMClient(config: config)) { error in
            XCTAssertEqual((error as? VoxError)?.code, .config)
        }
    }

    func testClientAcceptsLoopbackHTTPSAndOptedInLAN() throws {
        // A remote endpoint also requires the key to be present, so this
        // supplies one to keep the assertions about the scheme alone.
        let environment = ["LITELLM_API_KEY": "k"]
        var config = LLMConfig()
        XCTAssertNoThrow(try LiteLLMClient(config: config, environment: environment))

        config.baseURL = "https://api.openai.com/v1"
        XCTAssertNoThrow(try LiteLLMClient(config: config, environment: environment))

        config.baseURL = "http://192.168.1.10:4000/v1"
        config.allowInsecureHTTP = true
        XCTAssertNoThrow(try LiteLLMClient(config: config, environment: environment))
    }

    /// The error has to name what is exposed; the key env var is the part a
    /// reader would otherwise miss.
    func testErrorMentionsTheAPIKeyWhenOneIsConfigured() {
        var config = LLMConfig(apiKeyEnvVar: "LITELLM_API_KEY")
        config.baseURL = "http://litellm.internal/v1"
        XCTAssertThrowsError(try config.validateEndpointSecurity()) { error in
            XCTAssertTrue((error as? VoxError)?.detail?.contains("LITELLM_API_KEY") == true)
        }
    }

    func testLoopbackDetection() {
        for host in ["localhost", "LOCALHOST", "litellm.localhost", "127.0.0.1", "127.255.255.254", "::1"] {
            XCTAssertTrue(LLMConfig.isLoopback(host), host)
        }
        for host in ["", "127.0.0", "128.0.0.1", "1270.0.0.1", "example.com", "localhost.example.com"] {
            XCTAssertFalse(LLMConfig.isLoopback(host), host)
        }
    }
}
