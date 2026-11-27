import XCTest

@testable import VoxKit

final class LevelSmootherTests: XCTestCase {
    func testNormalizeClampsAndIsMonotonic() {
        XCTAssertEqual(LevelSmoother.normalize(db: -160), 0)
        XCTAssertEqual(LevelSmoother.normalize(db: -.infinity), 0)
        XCTAssertEqual(LevelSmoother.normalize(db: .nan), 0)
        XCTAssertEqual(LevelSmoother.normalize(db: 0), 1)
        XCTAssertEqual(LevelSmoother.normalize(db: 6), 1)
        XCTAssertLessThan(LevelSmoother.normalize(db: -40), LevelSmoother.normalize(db: -20))
    }

    func testAttackIsFastAndReleaseIsSlow() {
        var meter = LevelSmoother()
        meter.ingest(db: 0)
        for _ in 0..<6 { meter.advance(by: 1.0 / 60) }  // 100ms
        let risen = meter.level
        XCTAssertGreaterThan(risen, 0.9, "a loud syllable should register within ~100ms")

        meter.ingest(db: -160)
        for _ in 0..<6 { meter.advance(by: 1.0 / 60) }
        XCTAssertGreaterThan(meter.level, 0.3, "release must be gentler than attack")
        XCTAssertLessThan(meter.level, risen)
    }

    func testHeldReadingBridgesTheGapBetweenTapCallbacks() {
        var meter = LevelSmoother()
        meter.ingest(db: -10)
        // The tap fires every ~93ms at 44.1kHz; until the next reading the
        // bar should keep rising toward it, never sag.
        var previous = meter.level
        for _ in 0..<5 {
            meter.advance(by: 1.0 / 60)
            XCTAssertGreaterThanOrEqual(meter.level, previous)
            previous = meter.level
        }
    }

    func testDecaysToSilenceWhenReadingsStop() {
        var meter = LevelSmoother()
        meter.ingest(db: 0)
        for _ in 0..<120 { meter.advance(by: 1.0 / 60) }
        XCTAssertLessThan(meter.level, 0.05)
    }

    func testHistoryScrollsAtSampleRate() {
        var meter = LevelSmoother(capacity: 8, sampleInterval: 0.1)
        meter.ingest(db: 0)
        meter.advance(by: 0.05)
        XCTAssertEqual(meter.samples, Array(repeating: 0, count: 8))
        XCTAssertEqual(meter.scrollPhase, 0.5, accuracy: 1e-9)
        meter.advance(by: 0.06)
        XCTAssertEqual(meter.samples.count, 8)
        XCTAssertGreaterThan(meter.samples.last!, 0)
        XCTAssertEqual(meter.samples.dropLast().allSatisfy { $0 == 0 }, true)
    }

    func testFrameGapsAreClamped() {
        var meter = LevelSmoother(capacity: 8, sampleInterval: 0.1)
        meter.advance(to: 0)
        meter.ingest(db: 0)
        // The HUD was hidden for ten seconds: only one clamped frame of progress.
        meter.advance(to: 10)
        XCTAssertEqual(meter.samples.filter { $0 > 0 }.count, 1)
    }

    func testResetClearsHistory() {
        var meter = LevelSmoother(capacity: 4, sampleInterval: 0.01)
        meter.ingest(db: 0)
        meter.advance(by: 0.05)
        meter.reset()
        XCTAssertEqual(meter.level, 0)
        XCTAssertEqual(meter.samples, [0, 0, 0, 0])
    }
}
