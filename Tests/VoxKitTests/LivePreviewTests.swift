import XCTest

@testable import VoxKit

final class LivePreviewTests: XCTestCase {
    private let rate = 1000.0
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func scheduler(window: Double = 8, interval: Double = 1.5) -> LivePreviewScheduler {
        var scheduler = LivePreviewScheduler(
            config: LivePreviewConfig(enabled: true, windowSeconds: window, intervalSeconds: interval),
            sampleRate: rate
        )
        scheduler.start()
        return scheduler
    }

    private func at(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }

    // MARK: Config

    func testPreviewIsOffByDefaultAndAbsentFromOldConfigs() throws {
        XCTAssertFalse(VoxConfig().livePreview.enabled)
        let json = #"{"schema_version":1,"model":"small.en"}"#.data(using: .utf8)!
        let decoded = try VoxJSON.decoder().decode(VoxConfig.self, from: json)
        XCTAssertEqual(decoded.livePreview, .default)
        XCTAssertFalse(decoded.livePreview.enabled)
    }

    func testPreviewModelIsIndependentOfMainModel() {
        let config = VoxConfig()
        XCTAssertNotEqual(config.livePreview.model, config.model)
        XCTAssertNotNil(config.livePreview.resolvedModel)
    }

    func testConfigKeysRoundTripAndValidate() throws {
        var config = VoxConfig()
        try ConfigKeys.set("live_preview.enabled", to: "true", in: &config)
        try ConfigKeys.set("live_preview.model", to: "tiny.en", in: &config)
        try ConfigKeys.set("live_preview.window_seconds", to: "5", in: &config)
        try ConfigKeys.set("live_preview.interval_seconds", to: "1", in: &config)
        XCTAssertTrue(config.livePreview.enabled)
        XCTAssertEqual(config.livePreview.model, "tiny.en")
        XCTAssertEqual(try ConfigKeys.get("live_preview.window_seconds", from: config), "5.0")

        XCTAssertThrowsError(try ConfigKeys.set("live_preview.model", to: "nope", in: &config))
        XCTAssertThrowsError(try ConfigKeys.set("live_preview.window_seconds", to: "0", in: &config))
        XCTAssertThrowsError(try ConfigKeys.set("live_preview.window_seconds", to: "31", in: &config))
        XCTAssertThrowsError(try ConfigKeys.set("live_preview.interval_seconds", to: "0", in: &config))
    }

    // MARK: Scheduling

    func testNothingIsRequestedBeforeStartOrWithoutEnoughAudio() {
        var idle = LivePreviewScheduler(config: .default, sampleRate: rate)
        idle.audioDidGrow(totalSamples: 10_000)
        XCTAssertNil(idle.nextRequest(now: epoch))

        var scheduler = scheduler()
        XCTAssertNil(scheduler.nextRequest(now: epoch))
        scheduler.audioDidGrow(totalSamples: 400)  // under the 0.5 s floor
        XCTAssertNil(scheduler.nextRequest(now: epoch))
        scheduler.audioDidGrow(totalSamples: 600)
        let request = scheduler.nextRequest(now: epoch)
        XCTAssertEqual(request?.sampleRange, 0..<600)
        XCTAssertEqual(request?.commitsChunk, false)
    }

    func testOnlyOneRequestIsInFlightAndIntervalIsRespected() {
        var scheduler = scheduler(interval: 1.5)
        scheduler.audioDidGrow(totalSamples: 1000)
        let first = scheduler.nextRequest(now: at(0))!
        scheduler.audioDidGrow(totalSamples: 3000)
        XCTAssertNil(scheduler.nextRequest(now: at(5)), "a request is still running")

        XCTAssertNotNil(scheduler.complete(first, text: "hello"))
        XCTAssertNil(scheduler.nextRequest(now: at(1.0)), "interval not elapsed")
        let second = scheduler.nextRequest(now: at(1.5))
        XCTAssertEqual(second?.sampleRange, 0..<3000, "the volatile chunk is re-decoded from its start")
    }

    func testVolatileTextIsReplacedNotAppended() {
        var scheduler = scheduler()
        scheduler.audioDidGrow(totalSamples: 1000)
        let first = scheduler.nextRequest(now: at(0))!
        XCTAssertEqual(scheduler.complete(first, text: "hel")?.text, "hel")
        scheduler.audioDidGrow(totalSamples: 2000)
        let second = scheduler.nextRequest(now: at(2))!
        XCTAssertEqual(scheduler.complete(second, text: "hello there")?.text, "hello there")
        XCTAssertEqual(scheduler.snapshot.committed, "")
    }

    func testFullWindowCommitsChunkAndStartsTheNext() {
        var scheduler = scheduler(window: 8)
        scheduler.audioDidGrow(totalSamples: 9000)
        let request = scheduler.nextRequest(now: at(0))!
        XCTAssertEqual(request.sampleRange, 0..<8000)
        XCTAssertTrue(request.commitsChunk)
        let snapshot = scheduler.complete(request, text: "first chunk")!
        XCTAssertEqual(snapshot.committed, "first chunk")
        XCTAssertEqual(snapshot.volatile, "")

        // The 1000 samples past the boundary were never decoded, so the next
        // chunk starts there right away.
        let next = scheduler.nextRequest(now: at(2))!
        XCTAssertEqual(next.sampleRange, 8000..<9000)
        XCTAssertFalse(next.commitsChunk)
        XCTAssertEqual(scheduler.complete(next, text: "second")?.text, "first chunk second")
    }

    func testNoNewAudioMeansNoRequest() {
        var scheduler = scheduler()
        scheduler.audioDidGrow(totalSamples: 2000)
        let first = scheduler.nextRequest(now: at(0))!
        scheduler.complete(first, text: "x")
        scheduler.audioDidGrow(totalSamples: 2300)
        XCTAssertNil(scheduler.nextRequest(now: at(10)), "under 0.5 s of unseen audio")
        scheduler.audioDidGrow(totalSamples: 2500)
        XCTAssertNotNil(scheduler.nextRequest(now: at(10)))
    }

    // MARK: Discarding

    func testStopDiscardsPreviewAndRefusesLateResults() {
        var scheduler = scheduler()
        scheduler.audioDidGrow(totalSamples: 20_000)
        let commit = scheduler.nextRequest(now: at(0))!
        scheduler.complete(commit, text: "kept so far")
        let pending = scheduler.nextRequest(now: at(2))!
        XCTAssertFalse(scheduler.snapshot.isEmpty)

        scheduler.stop()
        XCTAssertEqual(scheduler.phase, .stopped)
        XCTAssertTrue(scheduler.snapshot.isEmpty, "the full pass is the only text that survives a stop")
        XCTAssertNil(scheduler.complete(pending, text: "late"))
        XCTAssertTrue(scheduler.snapshot.isEmpty)
        scheduler.audioDidGrow(totalSamples: 40_000)
        XCTAssertNil(scheduler.nextRequest(now: at(10)))
    }

    func testResultFromPreviousRecordingIsIgnoredAfterRestart() {
        var scheduler = scheduler()
        scheduler.audioDidGrow(totalSamples: 1000)
        let stale = scheduler.nextRequest(now: at(0))!
        scheduler.stop()
        scheduler.start()
        scheduler.audioDidGrow(totalSamples: 1000)
        let fresh = scheduler.nextRequest(now: at(5))!
        XCTAssertNotEqual(stale.generation, fresh.generation)
        XCTAssertNil(scheduler.complete(stale, text: "old"))
        XCTAssertEqual(scheduler.inFlight, fresh, "a stale result must not clear the live slot")
        XCTAssertEqual(scheduler.complete(fresh, text: "new")?.text, "new")
    }

    func testFailureFreesTheSlotAndKeepsWhatWasShown() {
        var scheduler = scheduler()
        scheduler.audioDidGrow(totalSamples: 1000)
        let first = scheduler.nextRequest(now: at(0))!
        scheduler.complete(first, text: "shown")
        scheduler.audioDidGrow(totalSamples: 2000)
        let second = scheduler.nextRequest(now: at(2))!
        scheduler.fail(second)
        XCTAssertNil(scheduler.inFlight)
        XCTAssertEqual(scheduler.snapshot.text, "shown")
        XCTAssertEqual(scheduler.nextRequest(now: at(4))?.sampleRange, second.sampleRange, "retried, not skipped")
    }

    // MARK: Text hygiene

    func testBracketedMarkersAndSilenceAreStripped() {
        XCTAssertEqual(LivePreviewText.clean("[BLANK_AUDIO]"), "")
        XCTAssertEqual(LivePreviewText.clean(" (music)  hello   world (laughs) "), "hello world")
        XCTAssertEqual(LivePreviewText.clean("..."), "")
        XCTAssertEqual(LivePreviewText.clean("  So,\n yes. "), "So, yes.")
        XCTAssertEqual(LivePreviewText.join("", "a"), "a")
        XCTAssertEqual(LivePreviewText.join("a", ""), "a")
        XCTAssertEqual(LivePreviewText.join("a", "b"), "a b")
    }

    func testEmptyChunkCommitsNothing() {
        var scheduler = scheduler(window: 2)
        scheduler.audioDidGrow(totalSamples: 2000)
        let request = scheduler.nextRequest(now: at(0))!
        XCTAssertTrue(request.commitsChunk)
        XCTAssertEqual(scheduler.complete(request, text: "[BLANK_AUDIO]")?.text, "")
        scheduler.audioDidGrow(totalSamples: 4000)
        let next = scheduler.nextRequest(now: at(2))!
        XCTAssertEqual(scheduler.complete(next, text: "hi")?.text, "hi")
    }
}
