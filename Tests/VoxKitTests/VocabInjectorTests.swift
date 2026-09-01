import XCTest

@testable import VoxKit

final class VocabInjectorTests: XCTestCase {
    func testNormalizeTrimsDeduplicatesAndPreservesOrder() {
        let normalized = VocabInjector.normalize(["  Kubernetes ", "", "kubernetes", "LiteLLM", "\n"])
        XCTAssertEqual(normalized, ["Kubernetes", "LiteLLM"])
    }

    func testInitialPromptIsNilWithoutTerms() {
        XCTAssertNil(VocabInjector.initialPrompt(vocabulary: []))
        XCTAssertNil(VocabInjector.initialPrompt(vocabulary: ["   "], extra: "  "))
    }

    func testInitialPromptFormatsGlossaryAndAppendsExtra() {
        let prompt = VocabInjector.initialPrompt(vocabulary: ["Vox", "whisper.cpp"], extra: "Technical dictation.")
        XCTAssertEqual(prompt, "Glossary: Vox, whisper.cpp. Technical dictation.")
    }

    func testTruncationCutsOnTermBoundary() {
        let terms = (0..<300).map { "term\($0)" }
        let prompt = VocabInjector.initialPrompt(vocabulary: terms)
        let unwrapped = try! XCTUnwrap(prompt)
        XCTAssertLessThanOrEqual(unwrapped.count, VocabInjector.maxPromptCharacters)
        XCTAssertTrue(unwrapped.hasSuffix("."))
        XCTAssertFalse(unwrapped.hasSuffix(",."))
    }
}
