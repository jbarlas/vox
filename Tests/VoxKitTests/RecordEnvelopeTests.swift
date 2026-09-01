import XCTest

@testable import VoxKit

/// The JSON envelope is a published contract with agent harnesses, so these
/// tests pin the field names, not just the round trip.
final class RecordEnvelopeTests: XCTestCase {
    private func sampleResult() -> RecordResult {
        let started = ISO8601.date(from: "2026-08-31T14:02:11Z")!
        return RecordResult(
            transcript: "check the deploy logs for errors",
            rawTranscript: "uh check the deploy logs for errors",
            mode: "cleanup",
            modeKind: .cleanup,
            model: "large-v3-turbo-q5_0",
            llmModel: nil,
            language: "en",
            durationMs: 2340,
            audioDurationMs: 1800,
            stopReason: .silence,
            startedAt: started,
            // Whole seconds: the envelope's ISO-8601 dates have second
            // resolution.
            finishedAt: started.addingTimeInterval(2),
            timings: RecordTimings(
                recordingMs: 1800, normalizeMs: 0, transcribeMs: 500, modeMs: 40, totalMs: 2340)
        )
    }

    func testSuccessEnvelopeFieldNames() throws {
        let json = try VoxJSON.string(RecordEnvelope(result: sampleResult()))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertNil(object["error"])

        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(
            Swift.Set(result.keys),
            Swift.Set([
                "transcript", "raw_transcript", "mode", "mode_kind", "model", "language",
                "duration_ms", "audio_duration_ms", "stop_reason", "started_at", "finished_at",
                "timings",
            ])
        )
        XCTAssertEqual(result["transcript"] as? String, "check the deploy logs for errors")
        XCTAssertEqual(result["stop_reason"] as? String, "silence")
        XCTAssertEqual(result["started_at"] as? String, "2026-08-31T14:02:11Z")

        let timings = try XCTUnwrap(result["timings"] as? [String: Any])
        XCTAssertEqual(
            Swift.Set(timings.keys),
            Swift.Set(["recording_ms", "normalize_ms", "transcribe_ms", "mode_ms", "total_ms"])
        )
    }

    func testLLMModelIsOmittedWhenUnused() throws {
        let json = try VoxJSON.string(RecordEnvelope(result: sampleResult()))
        XCTAssertFalse(json.contains("llm_model"))
    }

    func testErrorEnvelopeShape() throws {
        let error = VoxError(code: .timeout, message: "Recording timed out", detail: "after 30s")
        let json = try VoxJSON.string(RecordEnvelope(error: error))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertNil(object["result"])

        let errorObject = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(errorObject["code"] as? String, "timeout")
        XCTAssertEqual(errorObject["message"] as? String, "Recording timed out")
        XCTAssertEqual(errorObject["detail"] as? String, "after 30s")
    }

    func testEnvelopeRoundTrips() throws {
        let envelope = RecordEnvelope(result: sampleResult())
        let decoded = try VoxJSON.decoder().decode(
            RecordEnvelope.self,
            from: Data(try VoxJSON.string(envelope).utf8)
        )
        XCTAssertEqual(decoded, envelope)
    }

    func testEveryErrorCodeHasADistinctNonzeroExitCode() {
        let codes = VoxErrorCode.allCases.map(\.exitCode)
        XCTAssertFalse(codes.contains(0))
        XCTAssertEqual(Swift.Set(codes).count, codes.count)
    }
}
