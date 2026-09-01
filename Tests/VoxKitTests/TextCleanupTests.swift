import XCTest

@testable import VoxKit

final class TextCleanupTests: XCTestCase {
    func testRemovesFillerWordsAndFixesSpacing() {
        let cleaned = TextCleanup.clean("um so uh check the deploy logs , uh please")
        XCTAssertEqual(cleaned, "So check the deploy logs, please")
    }

    func testCollapsesStutteredRepeats() {
        XCTAssertEqual(TextCleanup.clean("check the the deploy logs"), "Check the deploy logs")
    }

    func testStripsNoiseAnnotations() {
        XCTAssertEqual(TextCleanup.clean("[BLANK_AUDIO] hello world"), "Hello world")
        XCTAssertEqual(TextCleanup.clean("(silence)"), "")
    }

    func testCapitalizesEachSentence() {
        XCTAssertEqual(
            TextCleanup.clean("deploy it. then check logs! did it work?"),
            "Deploy it. Then check logs! Did it work?"
        )
    }

    func testKeepsWordsThatOnlyLookLikeFiller() {
        // "so" and "like" are real words in context and must survive.
        XCTAssertEqual(TextCleanup.clean("so it works like a charm"), "So it works like a charm")
    }

    func testDoesNotRewriteWording() {
        let input = "Run make setup, then vox record --output json."
        XCTAssertEqual(TextCleanup.clean(input), input)
    }

    func testHandlesEmptyInput() {
        XCTAssertEqual(TextCleanup.clean(""), "")
        XCTAssertEqual(TextCleanup.clean("   "), "")
    }
}
