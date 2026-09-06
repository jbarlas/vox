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
        // "Cannot" splits cleanly into "can" + "not", both real words, but
        // "can not" is an ordinary, frequently-spoken phrase in its own
        // right — rejoining it would be a wrong, unintended correction.
        // Capitalized so this exercises the function-word guard specifically,
        // independent of the proper-noun casing guard below.
        XCTAssertEqual(VocabCorrector.compoundCandidates(in: ["Cannot"]).map(\.term), [])
        XCTAssertEqual(
            VocabCorrector.apply(vocabulary: ["Cannot"], to: "I can not do that today."),
            "I can not do that today."
        )
    }

    func testOnlyConsidersCapitalizedTermsProperNounCandidates() {
        // "multifamily" -> "multi" + "family" passes every other gate, but a
        // lowercase extracted term reads as an ordinary compound noun that's
        // genuinely spelled both ways ("multi family building"), not a proper
        // noun whisper is likely to have mis-split. Leave it alone.
        XCTAssertEqual(VocabCorrector.compoundCandidates(in: ["multifamily"]).map(\.term), [])
        XCTAssertEqual(
            VocabCorrector.apply(vocabulary: ["multifamily"], to: "it's a multi family building"),
            "it's a multi family building"
        )
        // The same split behind a capital letter is a candidate.
        XCTAssertEqual(VocabCorrector.compoundCandidates(in: ["Multifamily"]).map(\.term), ["Multifamily"])
    }

    func testDeduplicatesCaseInsensitiveCollisions() {
        XCTAssertEqual(
            VocabCorrector.compoundCandidates(in: ["Lightswitch", "lightswitch"]).map(\.term),
            ["Lightswitch"]
        )
    }
}
