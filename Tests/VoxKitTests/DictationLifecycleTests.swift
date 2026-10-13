import XCTest

@testable import VoxKit

@MainActor
final class DictationLifecycleTests: XCTestCase {
    func testQuitWaitsForRecordingProcessingAndOutputDelivery() async {
        let lifecycle = DictationLifecycle()
        let recording = expectation(description: "recording")
        let processing = expectation(description: "processing")
        let quit = expectation(description: "quit after output")
        var stopRecording: CheckedContinuation<Void, Never>?
        var finishProcessing: CheckedContinuation<Void, Never>?
        var events: [String] = []

        XCTAssertTrue(lifecycle.start {
            await withCheckedContinuation { continuation in
                stopRecording = continuation
                recording.fulfill()
            }
            events.append("recorded")
            await withCheckedContinuation { continuation in
                finishProcessing = continuation
                processing.fulfill()
            }
            events.append("delivered")
        })
        await fulfillment(of: [recording], timeout: 2)
        XCTAssertFalse(lifecycle.requestTermination {
            events.append("quit")
            quit.fulfill()
        })
        XCTAssertFalse(lifecycle.start { XCTFail("Must not start another dictation") })
        XCTAssertTrue(events.isEmpty)

        stopRecording?.resume()
        await fulfillment(of: [processing], timeout: 2)
        XCTAssertEqual(events, ["recorded"])
        finishProcessing?.resume()
        await fulfillment(of: [quit], timeout: 2)
        XCTAssertEqual(events, ["recorded", "delivered", "quit"])
        XCTAssertFalse(lifecycle.canStart)
        XCTAssertTrue(lifecycle.requestTermination { XCTFail("Already ready to quit") })
    }

    func testRepeatedQuitRequestsWaitForErrorHandlingToo() async {
        let lifecycle = DictationLifecycle()
        let active = expectation(description: "active")
        let quit = expectation(description: "quit once")
        var finish: CheckedContinuation<Void, Never>?
        var failureHandled = false
        lifecycle.start {
            await withCheckedContinuation { continuation in
                finish = continuation
                active.fulfill()
            }
            // The caller's error handling must complete before termination.
            failureHandled = true
        }
        await fulfillment(of: [active], timeout: 2)
        XCTAssertFalse(lifecycle.requestTermination { XCTFail("Replaced callback") })
        XCTAssertFalse(lifecycle.requestTermination {
            XCTAssertTrue(failureHandled)
            quit.fulfill()
        })
        finish?.resume()
        await fulfillment(of: [quit], timeout: 2)
    }

    func testIdleQuitIsImmediateAndPreventsNewDictation() {
        let lifecycle = DictationLifecycle()
        XCTAssertTrue(lifecycle.requestTermination { XCTFail("No deferred callback") })
        XCTAssertFalse(lifecycle.start { XCTFail("Shutdown has started") })
    }

    func testCompletedDictationAllowsAnotherSession() async {
        let lifecycle = DictationLifecycle()
        let first = expectation(description: "first session")
        lifecycle.start { first.fulfill() }
        XCTAssertFalse(lifecycle.start { XCTFail("Concurrent session") })
        await fulfillment(of: [first], timeout: 2)
        let second = expectation(description: "second session")
        XCTAssertTrue(lifecycle.start { second.fulfill() })
        await fulfillment(of: [second], timeout: 2)
        XCTAssertTrue(lifecycle.canStart)
    }
}
