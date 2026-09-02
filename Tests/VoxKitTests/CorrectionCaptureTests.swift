import XCTest

@testable import VoxKit

final class CorrectionCaptureTests: XCTestCase {
    private var directory: URL!
    private var paths: VoxPaths!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vox-corrections-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        paths = VoxPaths(supportDirectory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sampleResult(transcript: String = "check the deploy logs for errors") -> RecordResult {
        let started = ISO8601.date(from: "2026-08-31T14:02:11Z")!
        return RecordResult(
            transcript: transcript,
            rawTranscript: "uh check the deploy logs for errors",
            mode: "cleanup",
            modeKind: .cleanup,
            model: "large-v3-turbo-q5_0",
            language: "en",
            durationMs: 2340,
            audioDurationMs: 1800,
            stopReason: .silence,
            startedAt: started,
            finishedAt: started.addingTimeInterval(2),
            timings: RecordTimings(),
            confidence: TranscriptConfidence(minSegmentLogprob: -0.8, meanLogprob: -0.3, segmentCount: 2)
        )
    }

    // MARK: Config

    func testCorrectionsAreOffByDefaultAndMissingSectionDecodes() throws {
        let json = """
            {"model": "large-v3-turbo-q5_0", "mode": "raw", "language": "en"}
            """
        let config = try VoxJSON.decoder().decode(VoxConfig.self, from: Data(json.utf8))
        XCTAssertFalse(config.corrections.fixLast.enabled)
        XCTAssertFalse(config.corrections.preview.enabled)
        XCTAssertEqual(config.corrections.preview.idleTimeoutSeconds, 1.5)
        XCTAssertEqual(config.corrections.preview.display, .always)
    }

    func testPartialCorrectionsSectionFillsDefaults() throws {
        let json = """
            {"corrections": {"preview": {"enabled": true}}}
            """
        let config = try VoxJSON.decoder().decode(VoxConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.corrections.preview.enabled)
        XCTAssertEqual(config.corrections.preview.idleTimeoutSeconds, 1.5)
        XCTAssertEqual(config.corrections.fixLast, .default)
    }

    func testConfigKeysRoundTrip() throws {
        var config = VoxConfig()
        try ConfigKeys.set("corrections.fix_last.enabled", to: "true", in: &config)
        try ConfigKeys.set("corrections.fix_last.modifiers", to: "command+shift", in: &config)
        try ConfigKeys.set("corrections.preview.enabled", to: "yes", in: &config)
        try ConfigKeys.set("corrections.preview.idle_timeout_seconds", to: "2", in: &config)
        try ConfigKeys.set("corrections.preview.display", to: "lowConfidence", in: &config)
        try ConfigKeys.set("corrections.preview.confidence_threshold", to: "-1", in: &config)
        XCTAssertEqual(try ConfigKeys.get("corrections.fix_last.enabled", from: config), "true")
        XCTAssertEqual(
            try ConfigKeys.get("corrections.fix_last.modifiers", from: config), "command+shift")
        XCTAssertEqual(
            try ConfigKeys.get("corrections.preview.idle_timeout_seconds", from: config), "2.0")
        XCTAssertEqual(try ConfigKeys.get("corrections.preview.display", from: config), "lowConfidence")
        XCTAssertEqual(
            try ConfigKeys.get("corrections.preview.confidence_threshold", from: config), "-1.0")
        XCTAssertThrowsError(
            try ConfigKeys.set("corrections.preview.display", to: "sometimes", in: &config))
        XCTAssertThrowsError(
            try ConfigKeys.set("corrections.preview.idle_timeout_seconds", to: "0", in: &config))
    }

    func testFixLastDefaultDoesNotCollideWithRecordHotkey() throws {
        var config = VoxConfig()
        config.corrections.fixLast.enabled = true
        XCTAssertFalse(config.corrections.fixLast.collides(with: config.hotkey))
        XCTAssertNoThrow(try config.validate())

        config.corrections.fixLast.modifiers = config.hotkey.modifiers
        config.corrections.fixLast.keyCode = config.hotkey.keyCode
        XCTAssertTrue(config.corrections.fixLast.collides(with: config.hotkey))
        XCTAssertThrowsError(try config.validate())
    }

    func testPreviewGating() {
        var preview = PreviewConfig(enabled: true, display: .lowConfidence, confidenceThreshold: -0.6)
        let shaky = TranscriptConfidence(minSegmentLogprob: -0.9, meanLogprob: -0.2, segmentCount: 3)
        let solid = TranscriptConfidence(minSegmentLogprob: -0.1, meanLogprob: -0.05, segmentCount: 3)
        XCTAssertTrue(preview.shouldShow(confidence: shaky))
        XCTAssertFalse(preview.shouldShow(confidence: solid))
        XCTAssertTrue(preview.shouldShow(confidence: nil), "unknown confidence is not known-good")

        preview.display = .always
        XCTAssertTrue(preview.shouldShow(confidence: solid))
        preview.enabled = false
        XCTAssertFalse(preview.shouldShow(confidence: shaky))
    }

    func testConfidenceSummaryWeightsByTokens() {
        let confidence = TranscriptConfidence(segmentLogprobs: [(-1.0, 1), (-0.1, 3), (-5.0, 0)])
        XCTAssertEqual(confidence?.segmentCount, 2)
        XCTAssertEqual(confidence?.minSegmentLogprob, -1.0)
        XCTAssertEqual(confidence!.meanLogprob, -0.325, accuracy: 1e-9)
        XCTAssertNil(TranscriptConfidence(segmentLogprobs: []))
        XCTAssertNil(TranscriptConfidence(segmentLogprobs: [(-1.0, 0)]))
    }

    // MARK: Records

    func testUnchangedOrEmptyEditIsNotACorrection() {
        let result = sampleResult()
        XCTAssertNil(CorrectionRecord(result: result, corrected: result.transcript, variant: .preview))
        XCTAssertNil(
            CorrectionRecord(
                result: result, corrected: "  " + result.transcript + "\n", variant: .preview))
        XCTAssertNil(CorrectionRecord(result: result, corrected: "", variant: .fixLast))
        XCTAssertNotNil(
            CorrectionRecord(
                result: result, corrected: "check the deploy logs for errors.", variant: .fixLast))
    }

    func testRecordFieldNamesAndTagging() throws {
        let created = ISO8601.date(from: "2026-09-02T03:54:11Z")!
        let record = try XCTUnwrap(
            CorrectionRecord(
                result: sampleResult(), corrected: " check the deploy logs for Erin ", variant: .fixLast,
                createdAt: created))
        let json = try VoxJSON.string(record)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(
            Swift.Set(object.keys),
            Swift.Set([
                "schema_version", "id", "created_at", "variant", "raw_transcript", "original_transcript",
                "corrected_transcript", "mode", "mode_kind", "model", "language", "confidence",
                "dictation_finished_at",
            ])
        )
        XCTAssertEqual(
            object["variant"] as? String, "fixLast", "enum raw values stay camelCase, like stop_reason")
        XCTAssertEqual(object["mode_kind"] as? String, "cleanup")
        XCTAssertEqual(object["corrected_transcript"] as? String, "check the deploy logs for Erin")
        XCTAssertEqual(object["raw_transcript"] as? String, "uh check the deploy logs for errors")
        XCTAssertEqual(object["created_at"] as? String, "2026-09-02T03:54:11Z")
        let confidence = try XCTUnwrap(object["confidence"] as? [String: Any])
        XCTAssertEqual(
            Swift.Set(confidence.keys),
            Swift.Set(["min_segment_logprob", "mean_logprob", "segment_count"]))
    }

    func testStoreWritesOneFilePerRecordAndReadsInOrder() throws {
        let store = CorrectionStore(paths: paths)
        let first = try XCTUnwrap(
            CorrectionRecord(
                result: sampleResult(), corrected: "first", variant: .preview,
                createdAt: ISO8601.date(from: "2026-09-02T03:54:11Z")!))
        let second = try XCTUnwrap(
            CorrectionRecord(
                result: sampleResult(), corrected: "second", variant: .fixLast,
                createdAt: ISO8601.date(from: "2026-09-02T03:55:00Z")!))
        let url = try store.append(second)
        try store.append(first)
        XCTAssertEqual(url.deletingLastPathComponent(), paths.correctionsDirectory)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("2026-09-02T03-55-00Z-"))
        XCTAssertFalse(url.lastPathComponent.contains(":"))

        // telemetry.json in the same directory must not be mistaken for a record.
        try CorrectionTelemetryStore(paths: paths).record(.invoked, for: .preview)
        try Data("not json".utf8).write(
            to: paths.correctionsDirectory.appendingPathComponent("junk.json"))

        let records = try store.records()
        XCTAssertEqual(records.map(\.correctedTranscript), ["first", "second"])
        XCTAssertEqual(records, [first, second])
        XCTAssertEqual(store.count(), 2)
    }

    func testEmptyStore() throws {
        XCTAssertEqual(try CorrectionStore(paths: paths).records(), [])
        XCTAssertEqual(CorrectionTelemetryStore(paths: paths).load(), CorrectionTelemetry())
    }

    // MARK: Telemetry

    func testTelemetryCountsPerVariantAndPersists() throws {
        let store = CorrectionTelemetryStore(paths: paths)
        try store.record(.invoked, for: .fixLast)
        try store.record(.invoked, for: .fixLast)
        try store.record(.corrected, for: .fixLast)
        try store.record(.invokedEmpty, for: .fixLast)
        try store.record(.invoked, for: .preview)
        try store.record(.autoCommitted, for: .preview)
        try store.record(.cancelled, for: .preview)

        let telemetry = CorrectionTelemetryStore(paths: paths).load()
        XCTAssertEqual(telemetry.fixLast.invocations, 2)
        XCTAssertEqual(telemetry.fixLast.corrections, 1)
        XCTAssertEqual(telemetry.fixLast.emptyInvocations, 1)
        XCTAssertEqual(telemetry.preview.invocations, 1)
        XCTAssertEqual(telemetry.preview.autoCommits, 1)
        XCTAssertEqual(telemetry.preview.cancelled, 1)
        XCTAssertEqual(telemetry.preview.corrections, 0)
        XCTAssertNotNil(telemetry.updatedAt)

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: paths.correctionTelemetryFile))
                as? [String: Any])
        XCTAssertEqual(
            Swift.Set(object.keys), Swift.Set(["schema_version", "fix_last", "preview", "updated_at"]))
        let fixLast = try XCTUnwrap(object["fix_last"] as? [String: Any])
        XCTAssertEqual(fixLast["empty_invocations"] as? Int, 1)
    }

    func testTelemetryToleratesOlderOrCorruptFiles() throws {
        try FileManager.default.createDirectory(
            at: paths.correctionsDirectory, withIntermediateDirectories: true)
        try Data(#"{"fix_last": {"invocations": 4}}"#.utf8).write(to: paths.correctionTelemetryFile)
        let store = CorrectionTelemetryStore(paths: paths)
        XCTAssertEqual(store.load().fixLast.invocations, 4)
        XCTAssertEqual(store.load().preview, CorrectionTelemetry.VariantCounts())

        try Data("{".utf8).write(to: paths.correctionTelemetryFile)
        XCTAssertEqual(store.load(), CorrectionTelemetry())
        try store.record(.invoked, for: .preview)
        XCTAssertEqual(store.load().preview.invocations, 1)
    }

    func testTelemetryConcurrentWritesLoseNothing() throws {
        let store = CorrectionTelemetryStore(paths: paths)
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            try? CorrectionTelemetryStore(paths: paths).record(.invoked, for: .preview)
        }
        XCTAssertEqual(store.load().preview.invocations, 12)
    }

    // MARK: Preview state machine

    func testUntouchedPreviewAutoCommitsOriginal() {
        var session = PreviewSession(text: "hello", idleTimeoutSeconds: 1.5)
        XCTAssertEqual(session.start(), [.armIdleTimer(seconds: 1.5)])
        let commit = PreviewSession.Commit(text: "hello", reason: .idleTimeout, changed: false)
        XCTAssertEqual(session.idleTimerFired(), [.commit(commit)])
        XCTAssertTrue(session.isClosed)
        XCTAssertEqual(commit.telemetryEvent, .autoCommitted)
        XCTAssertEqual(session.confirm(), [], "a closed session ignores further input")
        XCTAssertEqual(session.idleTimerFired(), [])
    }

    func testTypingCancelsTimerAndConfirmCommitsEdit() {
        var session = PreviewSession(text: "hello", idleTimeoutSeconds: 1.5)
        _ = session.start()
        XCTAssertEqual(session.textDidChange("hell"), [.cancelIdleTimer])
        XCTAssertEqual(session.textDidChange("hello there"), [], "timer already cancelled")
        XCTAssertEqual(session.phase, .editing)
        XCTAssertEqual(session.idleTimerFired(), [], "a late timer must not paste over an edit")
        XCTAssertFalse(session.isClosed)
        let commit = PreviewSession.Commit(text: "hello there", reason: .confirmed, changed: true)
        XCTAssertEqual(session.confirm(), [.commit(commit)])
        XCTAssertEqual(commit.telemetryEvent, .corrected)
    }

    func testEditingBackToOriginalIsConfirmedUnchanged() {
        var session = PreviewSession(text: "hello", idleTimeoutSeconds: 1.5)
        _ = session.start()
        _ = session.textDidChange("hellp")
        _ = session.textDidChange("hello ")
        let commit = PreviewSession.Commit(text: "hello", reason: .confirmed, changed: false)
        XCTAssertEqual(session.confirm(), [.commit(commit)])
        XCTAssertEqual(commit.telemetryEvent, .confirmedUnchanged)
    }

    func testImmediateReturnCommitsAndCancelsTimer() {
        var session = PreviewSession(text: "hello", idleTimeoutSeconds: 1.5)
        _ = session.start()
        XCTAssertEqual(
            session.confirm(),
            [
                .cancelIdleTimer,
                .commit(PreviewSession.Commit(text: "hello", reason: .confirmed, changed: false)),
            ])
    }

    func testEscapeDismissesWithoutCommit() {
        var session = PreviewSession(text: "hello", idleTimeoutSeconds: 1.5)
        _ = session.start()
        XCTAssertEqual(session.cancel(), [.cancelIdleTimer, .dismiss])
        XCTAssertTrue(session.isClosed)

        var edited = PreviewSession(text: "hello", idleTimeoutSeconds: 1.5)
        _ = edited.start()
        _ = edited.textDidChange("x")
        XCTAssertEqual(edited.cancel(), [.dismiss])
    }

    func testEmptiedTextConfirmIsACancel() {
        var session = PreviewSession(text: "hello", idleTimeoutSeconds: 1.5)
        _ = session.start()
        _ = session.textDidChange("   ")
        XCTAssertEqual(session.confirm(), [.dismiss])
    }

    func testFixLastSessionNeverTimesOut() {
        var session = PreviewSession(text: "hello", idleTimeoutSeconds: nil)
        XCTAssertEqual(session.start(), [])
        XCTAssertEqual(session.textDidChange("hello!"), [])
        XCTAssertEqual(session.idleTimerFired(), [])
        XCTAssertEqual(
            session.confirm(),
            [.commit(PreviewSession.Commit(text: "hello!", reason: .confirmed, changed: true))])

        var untouched = PreviewSession(text: "hello", idleTimeoutSeconds: nil)
        XCTAssertEqual(untouched.cancel(), [.dismiss])
    }
}
