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

    // MARK: - Contextual fillers

    func testStripsLikeSetOffByCommas() {
        XCTAssertEqual(TextCleanup.clean("it was, like, totally broken"), "It was totally broken")
        XCTAssertEqual(TextCleanup.clean("it was, Like, totally broken"), "It was totally broken")
    }

    func testStripsSentenceInitialFillerFollowedByComma() {
        XCTAssertEqual(TextCleanup.clean("Like, we should fix it"), "We should fix it")
        XCTAssertEqual(TextCleanup.clean("So, it works"), "It works")
        XCTAssertEqual(TextCleanup.clean("Okay, ship it"), "Ship it")
        XCTAssertEqual(
            TextCleanup.clean("It broke. So, we should fix it."), "It broke. We should fix it.")
    }

    func testStripsRunOfAdjacentFillers() {
        XCTAssertEqual(TextCleanup.clean("so, like, we should fix it"), "We should fix it")
        XCTAssertEqual(TextCleanup.clean("so like, we should fix it"), "We should fix it")
        XCTAssertEqual(TextCleanup.clean("okay so, um, like, the build failed"), "The build failed")
    }

    func testStripsCommaSeparatedRunMidSentence() {
        XCTAssertEqual(TextCleanup.clean("it was, so, like, broken"), "It was broken")
        XCTAssertEqual(TextCleanup.clean("it was, okay, so, like, you know, broken"), "It was broken")
        XCTAssertEqual(TextCleanup.clean("it was, so, like broken"), "It was, so, like broken")
    }

    func testIgnoresQuotesWhenDetectingPauses() {
        XCTAssertEqual(TextCleanup.clean("he said, \"like,\" maybe"), "He said maybe")
        XCTAssertEqual(TextCleanup.clean("He said \"it broke.\" So, fix it"), "He said \"it broke.\" Fix it")
        XCTAssertEqual(TextCleanup.clean("he said \"I like,\" then paused"), "He said \"I like,\" then paused")
    }

    func testStripsTrailingFillerAtSentenceEnd() {
        XCTAssertEqual(TextCleanup.clean("we should fix it, you know."), "We should fix it.")
        XCTAssertEqual(TextCleanup.clean("we should fix it, like"), "We should fix it")
        XCTAssertEqual(TextCleanup.clean("it is broken, I mean, unusable"), "It is broken unusable")
    }

    func testStripsMultiWordFillers() {
        XCTAssertEqual(TextCleanup.clean("it's, kind of, done"), "It's done")
        XCTAssertEqual(TextCleanup.clean("You know, the tests pass"), "The tests pass")
        XCTAssertEqual(TextCleanup.clean("I mean, the tests pass"), "The tests pass")
        XCTAssertEqual(TextCleanup.clean("it was, sort of, slow"), "It was slow")
    }

    func testKeepsMeaningfulLike() {
        XCTAssertEqual(TextCleanup.clean("I like that idea"), "I like that idea")
        XCTAssertEqual(TextCleanup.clean("it looks like a bug"), "It looks like a bug")
        XCTAssertEqual(TextCleanup.clean("I like, really like it"), "I like, really like it")
        XCTAssertEqual(TextCleanup.clean("things like, say, retries"), "Things like, say, retries")
        XCTAssertEqual(TextCleanup.clean("it works, uh, like a charm"), "It works, like a charm")
    }

    func testKeepsMeaningfulSo() {
        XCTAssertEqual(TextCleanup.clean("so far it works"), "So far it works")
        XCTAssertEqual(TextCleanup.clean("So far, it works"), "So far, it works")
        XCTAssertEqual(TextCleanup.clean("I hope so, anyway"), "I hope so, anyway")
        XCTAssertEqual(TextCleanup.clean("it was so slow"), "It was so slow")
        XCTAssertEqual(TextCleanup.clean("okay so the build failed"), "Okay so the build failed")
    }

    func testKeepsMeaningfulMultiWordPhrases() {
        XCTAssertEqual(TextCleanup.clean("that kind of thing"), "That kind of thing")
        XCTAssertEqual(TextCleanup.clean("what sort of error"), "What sort of error")
        XCTAssertEqual(TextCleanup.clean("I mean it"), "I mean it")
        XCTAssertEqual(TextCleanup.clean("do you know the answer"), "Do you know the answer")
        XCTAssertEqual(
            TextCleanup.clean("Do you know, I never checked"), "Do you know, I never checked")
        XCTAssertEqual(TextCleanup.clean("it's okay, thanks"), "It's okay, thanks")
    }

    func testKeepsFillerWordsWithoutPunctuationCues() {
        // Without commas the word is ambiguous; a miss beats a mangled sentence.
        XCTAssertEqual(TextCleanup.clean("like we should fix it"), "Like we should fix it")
        XCTAssertEqual(TextCleanup.clean("so we should fix it"), "So we should fix it")
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
