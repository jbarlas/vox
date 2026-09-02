import XCTest

@testable import VoxKit

final class VocabCorrectorTests: XCTestCase {
    func testRejoinsSplitCompoundMatchingSeededSpelling() {
        let result = VocabCorrector.apply(
            vocabulary: ["Lightswitch"],
            to: "Go flip the light switch in the hallway."
        )
        XCTAssertEqual(result, "Go flip the Lightswitch in the hallway.")
    }

    func testIsCaseInsensitiveAndMatchesWholeWordsOnly() {
        XCTAssertEqual(
            VocabCorrector.apply(vocabulary: ["Lightswitch"], to: "LIGHT SWITCH is broken"),
            "Lightswitch is broken"
        )
        // "highlight switch" contains "light switch" but not on a word
        // boundary, so it must be left alone.
        XCTAssertEqual(
            VocabCorrector.apply(vocabulary: ["Lightswitch"], to: "the highlight switch settings"),
            "the highlight switch settings"
        )
    }

    func testLeavesTermsWithoutARecognizedTwoWordSplitAlone() {
        // "kubernetes" has no split into two dictionary words, so nothing
        // should be touched even though it's in the vocabulary.
        XCTAssertEqual(
            VocabCorrector.apply(vocabulary: ["Kubernetes"], to: "we deployed to kubernetes"),
            "we deployed to kubernetes"
        )
    }

    func testIgnoresTermsThatAreAlreadyMultipleWordsOrHaveConnectors() {
        // Only single-run terms are compound candidates; anything with an
        // internal separator already reads as multiple words.
        XCTAssertEqual(
            VocabCorrector.compoundCandidates(in: ["whisper.cpp", "O'Brien", "New York"]).map(\.term),
            []
        )
    }

    func testRejectsSplitsWhereEitherHalfIsAFunctionWord() {
        // "cannot" splits cleanly into "can" + "not", both real words, but
        // "can not" is an ordinary, frequently-spoken phrase in its own
        // right — rejoining it would be a wrong, unintended correction.
        XCTAssertEqual(VocabCorrector.compoundCandidates(in: ["cannot"]).map(\.term), [])
        XCTAssertEqual(
            VocabCorrector.apply(vocabulary: ["cannot"], to: "I can not do that today."),
            "I can not do that today."
        )
    }

    func testDeduplicatesCaseInsensitiveCollisions() {
        XCTAssertEqual(
            VocabCorrector.compoundCandidates(in: ["Lightswitch", "lightswitch"]).map(\.term),
            ["Lightswitch"]
        )
    }
}
