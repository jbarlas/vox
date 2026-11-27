import XCTest

@testable import VoxKit

final class HUDStateMachineTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func llmDictation(_ machine: inout HUDStateMachine) {
        machine.send(.began)
        machine.send(.recordingStarted(at: t0))
        machine.send(.transcriptionStarted)
        machine.send(.llmRequestStarted(mode: "polish", model: "phi4-mini", at: t0.addingTimeInterval(3)))
    }

    func testLLMDictationWalksEveryPhase() {
        var machine = HUDStateMachine()
        XCTAssertEqual(machine.phase, .hidden)
        machine.send(.began)
        XCTAssertEqual(machine.phase, .starting)
        machine.send(.recordingStarted(at: t0))
        XCTAssertEqual(machine.phase, .recording(since: t0))
        machine.send(.transcriptionStarted)
        XCTAssertEqual(machine.phase, .transcribing)
        machine.send(.llmRequestStarted(mode: "polish", model: "phi4-mini", at: t0.addingTimeInterval(3)))
        XCTAssertEqual(machine.phase, .refining(mode: "polish", model: "phi4-mini", since: t0.addingTimeInterval(3)))
        machine.send(.delivered(Delivery(
            destination: .clipboard, transcriptIsEmpty: false, mode: "polish", usedLLM: true, modeElapsed: 1.84
        )))
        XCTAssertEqual(machine.phase, .succeeded(HUDOutcome(title: "Copied", detail: "Refined with polish · 1.8s")))
        XCTAssertEqual(HUDStateMachine.autoDismissDelay(for: machine.phase), 1.4)
        machine.send(.dismissed(generation: machine.generation))
        XCTAssertEqual(machine.phase, .hidden)
    }

    func testNonLLMModeSkipsTheRefiningPhase() {
        var machine = HUDStateMachine()
        machine.send(.began)
        machine.send(.recordingStarted(at: t0))
        machine.send(.transcriptionStarted)
        // A raw/cleanup mode never sends a request, so no waiting phase.
        XCTAssertEqual(machine.phase, .transcribing)
        machine.send(.delivered(Delivery(destination: .autoPaste, transcriptIsEmpty: false, mode: "cleanup", usedLLM: false)))
        XCTAssertEqual(machine.phase, .succeeded(HUDOutcome(title: "Pasted")))
    }

    func testLateStageEventsNeverStepBackwards() {
        var machine = HUDStateMachine()
        llmDictation(&machine)
        // Stage callbacks hop to the main actor in separate tasks; a stale
        // one landing late must not drag the HUD back to "Transcribing".
        machine.send(.transcriptionStarted)
        machine.send(.recordingStarted(at: t0))
        XCTAssertEqual(machine.phase, .refining(mode: "polish", model: "phi4-mini", since: t0.addingTimeInterval(3)))

        machine.send(.delivered(Delivery(destination: .clipboard, transcriptIsEmpty: false, mode: "polish", usedLLM: true)))
        let done = machine.phase
        machine.send(.llmRequestStarted(mode: "polish", model: nil, at: t0))
        machine.send(.transcriptionStarted)
        XCTAssertEqual(machine.phase, done)
    }

    func testStageEventsWithoutADictationAreIgnored() {
        var machine = HUDStateMachine()
        machine.send(.recordingStarted(at: t0))
        machine.send(.delivered(Delivery(destination: .clipboard, transcriptIsEmpty: false, mode: "raw", usedLLM: false)))
        XCTAssertEqual(machine.phase, .hidden)
    }

    func testStaleDismissDoesNotHideTheNextDictation() {
        var machine = HUDStateMachine()
        llmDictation(&machine)
        machine.send(.delivered(Delivery(destination: .clipboard, transcriptIsEmpty: false, mode: "polish", usedLLM: true)))
        let firstGeneration = machine.generation

        machine.send(.began)
        machine.send(.dismissed(generation: firstGeneration))
        XCTAssertEqual(machine.phase, .starting)

        // A dismiss for the current generation is still ignored mid-flight.
        machine.send(.dismissed(generation: machine.generation))
        XCTAssertEqual(machine.phase, .starting)
    }

    func testEveryNewDictationIsPresentedEvenOverAShowingResult() {
        var machine = HUDStateMachine()
        XCTAssertEqual(machine.send(.began), .present)
        machine.send(.recordingStarted(at: t0))
        machine.send(.delivered(Delivery(destination: .clipboard, transcriptIsEmpty: false, mode: "raw", usedLLM: false)))
        // Restarted while "Copied" is still up — maybe from another display:
        // the window layer must re-place the panel, not just re-render it.
        XCTAssertEqual(machine.send(.began), .present)
        XCTAssertEqual(machine.phase, .starting)
        // Restarted while still starting: same phase, still re-presented.
        XCTAssertEqual(machine.send(.began), .present)
    }

    func testHideEffectOnlyWhenLeavingAVisiblePhase() {
        var machine = HUDStateMachine()
        XCTAssertEqual(machine.send(.cancelled), .none)
        machine.send(.began)
        XCTAssertEqual(machine.send(.recordingStarted(at: t0)), .none)
        XCTAssertEqual(machine.send(.cancelled), .hide)
    }

    func testPermissionFailureNamesTheRightPermission() {
        // OutputRouter.paste's message when auto-paste is denied.
        let paste = VoxError(code: .permission, message: "Auto-paste needs Accessibility permission")
        XCTAssertEqual(HUDStateMachine.failure(for: paste).title, "Accessibility access needed")
        // AudioCapture.record's message.
        let mic = VoxError(code: .permission, message: "Microphone access was denied")
        XCTAssertEqual(HUDStateMachine.failure(for: mic).title, "Microphone access needed")
    }

    func testCancelHidesImmediately() {
        var machine = HUDStateMachine()
        machine.send(.began)
        machine.send(.cancelled)
        XCTAssertEqual(machine.phase, .hidden)
    }

    func testLLMTimeoutShowsFallbackNote() {
        var machine = HUDStateMachine()
        llmDictation(&machine)
        let error = VoxError.llm(LLMFailureMessage.timeout(endpoint: "http://127.0.0.1:4000/v1/chat/completions", seconds: 30))
        machine.send(.delivered(Delivery(
            destination: .clipboard, transcriptIsEmpty: false, mode: "polish", usedLLM: true,
            modeError: error, modeElapsed: 30.02
        )))
        XCTAssertEqual(machine.phase, .failed(HUDFailure(
            title: "LLM timed out after 30s", detail: error.message, fallbackNote: "Raw transcript copied instead"
        )))
        XCTAssertEqual(HUDStateMachine.autoDismissDelay(for: machine.phase), 4.0)
    }

    func testLLMUnreachableAndEmptyAndHTTPFailures() {
        func failure(_ error: VoxError, destination: OutputConfig.Destination = .clipboard) -> HUDPhase {
            HUDStateMachine.phase(for: Delivery(
                destination: destination, transcriptIsEmpty: false, mode: "polish", usedLLM: true, modeError: error
            ))
        }
        XCTAssertEqual(
            failure(VoxError.llm(LLMFailureMessage.unreachable(endpoint: "http://127.0.0.1:4000")), destination: .autoPaste),
            .failed(HUDFailure(title: "LLM unreachable", detail: "Is the endpoint running?", fallbackNote: "Raw transcript pasted instead"))
        )
        let empty = VoxError.llm(LLMFailureMessage.emptyResponse)
        XCTAssertEqual(
            failure(empty),
            .failed(HUDFailure(title: "LLM returned an empty reply", detail: empty.message, fallbackNote: "Raw transcript copied instead"))
        )
        let http = VoxError.llm(LLMFailureMessage.httpStatus(503))
        XCTAssertEqual(
            failure(http, destination: .none),
            .failed(HUDFailure(title: "LLM error · HTTP 503", detail: http.message, fallbackNote: "Kept the raw transcript instead"))
        )
    }

    func testOutrightFailureHasNoFallbackNote() {
        var machine = HUDStateMachine()
        machine.send(.began)
        machine.send(.failed(VoxError(code: .microphone, message: "Could not start the audio engine")))
        XCTAssertEqual(machine.phase, .failed(HUDFailure(
            title: "Microphone unavailable", detail: "Could not start the audio engine"
        )))
        XCTAssertEqual(HUDStateMachine.autoDismissDelay(for: machine.phase), 4.5)
    }

    func testEmptyTranscriptIsANotice() {
        let phase = HUDStateMachine.phase(for: Delivery(destination: .clipboard, transcriptIsEmpty: true, mode: "polish", usedLLM: true))
        XCTAssertEqual(phase, .succeeded(HUDOutcome(style: .notice, title: "No speech detected")))
    }

    func testInFlightPhasesNeverAutoDismiss() {
        XCTAssertNil(HUDStateMachine.autoDismissDelay(for: .starting))
        XCTAssertNil(HUDStateMachine.autoDismissDelay(for: .recording(since: t0)))
        XCTAssertNil(HUDStateMachine.autoDismissDelay(for: .transcribing))
        XCTAssertNil(HUDStateMachine.autoDismissDelay(for: .refining(mode: "polish", model: nil, since: t0)))
    }
}

final class LLMFailureKindTests: XCTestCase {
    func testClassifiesTheClientsRealResponseErrors() {
        let empty = #"{"choices":[{"message":{"content":""}}]}"#.data(using: .utf8)!
        let garbage = "<html>bad gateway</html>".data(using: .utf8)!
        XCTAssertThrowsError(try LiteLLMClient.text(fromResponse: empty)) { error in
            XCTAssertEqual(LLMFailureKind.classify(error as! VoxError), .emptyResponse)
        }
        XCTAssertThrowsError(try LiteLLMClient.text(fromResponse: garbage)) { error in
            XCTAssertEqual(LLMFailureKind.classify(error as! VoxError), .invalidResponse)
        }
    }

    func testClassifiesMessageShapes() {
        XCTAssertEqual(LLMFailureKind.classify(.llm(LLMFailureMessage.timeout(endpoint: "x", seconds: 5))), .timeout)
        XCTAssertEqual(LLMFailureKind.classify(.llm(LLMFailureMessage.unreachable(endpoint: "x"))), .unreachable)
        XCTAssertEqual(LLMFailureKind.classify(.llm(LLMFailureMessage.httpStatus(401))), .httpStatus(401))
        XCTAssertEqual(LLMFailureKind.classify(.config("llm.base_url is not a valid URL")), .misconfigured)
        XCTAssertEqual(LLMFailureKind.classify(.llm("OPENAI_API_KEY is not set, and api.openai.com needs an API key")), .misconfigured)
        XCTAssertEqual(LLMFailureKind.classify(.llm("something else")), .other)
    }
}
