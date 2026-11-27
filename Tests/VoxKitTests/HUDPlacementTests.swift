import XCTest

@testable import VoxKit

final class HUDPlacementTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)

    func testPointerOnASecondDisplaysTopEdgePicksThatDisplay() {
        // Reaching for the menu bar parks the pointer at exactly maxY, which
        // a half-open contains() treats as "no screen".
        XCTAssertEqual(HUDPlacement.screenIndex(containing: CGPoint(x: 2000, y: 1440), frames: [main, external]), 1)
        XCTAssertEqual(HUDPlacement.screenIndex(containing: CGPoint(x: 4072, y: 700), frames: [main, external]), 1)
        XCTAssertEqual(HUDPlacement.screenIndex(containing: CGPoint(x: 10, y: 10), frames: [main, external]), 0)
    }

    func testPointerOutsideEveryScreenPicksTheNearest() {
        XCTAssertEqual(HUDPlacement.screenIndex(containing: CGPoint(x: 5000, y: 100), frames: [main, external]), 1)
        XCTAssertNil(HUDPlacement.screenIndex(containing: .zero, frames: []))
    }

    func testDefaultsToTopCentre() {
        let visible = CGRect(x: 0, y: 70, width: 1512, height: 880)
        let placement = HUDPlacement.frame(size: CGSize(width: 400, height: 80), in: visible, avoiding: [CGRect(x: 700, y: 400, width: 2, height: 18)])
        XCTAssertEqual(placement.edge, .top)
        XCTAssertEqual(placement.frame, CGRect(x: 556, y: 950 - 80 - 10, width: 400, height: 80))
    }

    func testMovesToBottomWhenTheCaretIsUnderTheTopSlot() {
        let visible = CGRect(x: 0, y: 70, width: 1512, height: 880)
        let caret = CGRect(x: 760, y: 900, width: 2, height: 18)
        let placement = HUDPlacement.frame(size: CGSize(width: 400, height: 80), in: visible, avoiding: [caret])
        XCTAssertEqual(placement.edge, .bottom)
        XCTAssertEqual(placement.frame.minY, 80)
    }

    func testStaysTopWhenBothSlotsAreObstructed() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let placement = HUDPlacement.frame(
            size: CGSize(width: 400, height: 80), in: visible,
            avoiding: [CGRect(x: 500, y: 560, width: 2, height: 2), CGRect(x: 500, y: 20, width: 2, height: 2)]
        )
        XCTAssertEqual(placement.edge, .top)
    }
}

final class PanelVisibilityTests: XCTestCase {
    func testStaleFadeOutCannotHideAPanelShownDuringTheFade() {
        var visibility = PanelVisibility()
        visibility.show()
        let fade = visibility.hide()!
        // Next dictation starts before the 200ms fade-out finishes.
        visibility.show()
        XCTAssertFalse(visibility.shouldOrderOut(afterHide: fade))
        XCTAssertTrue(visibility.isShown)
    }

    func testOnlyTheLatestHideOrdersOut() {
        var visibility = PanelVisibility()
        visibility.show()
        let first = visibility.hide()!
        visibility.show()
        let second = visibility.hide()!
        XCTAssertFalse(visibility.shouldOrderOut(afterHide: first))
        XCTAssertTrue(visibility.shouldOrderOut(afterHide: second))
    }

    func testHideWhenAlreadyHiddenIsANoOp() {
        var visibility = PanelVisibility()
        XCTAssertNil(visibility.hide())
        visibility.show()
        XCTAssertNotNil(visibility.hide())
        XCTAssertNil(visibility.hide())
    }
}
