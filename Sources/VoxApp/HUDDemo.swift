import Foundation
import VoxKit

/// `VOX_HUD_DEMO=1 open dist/Vox.app` (or run the binary with it set) loops
/// the HUD through every phase with a synthetic voice-like level signal, so
/// its look can be checked without a microphone or an LLM. Nothing here runs
/// unless that variable is set.
@MainActor
enum HUDDemo {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["VOX_HUD_DEMO"] != nil }

    static func run(on overlay: RecordingOverlayController) {
        Task { @MainActor in
            let clock = ContinuousClock()
            @MainActor func pause(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
            @MainActor func speak(for seconds: Double) async {
                let start = clock.now
                var t = 0.0
                while clock.now - start < .milliseconds(Int(seconds * 1000)) {
                    // Syllable-ish bursts at the capture tap's ~11.7Hz cadence.
                    let envelope = max(0, sin(t * 5.3)) * 0.7 + max(0, sin(t * 1.7)) * 0.3
                    overlay.update(levelDB: -58 + 52 * envelope + Double.random(in: -4...4))
                    t += 0.0853
                    await pause(0.0853)
                }
            }
            let llmTimeout = VoxError.llm("LLM endpoint at http://127.0.0.1:11434/v1/chat/completions didn't respond within 60s")
            let scenarios: [(String, VoxError?)] = [
                ("ok", nil),
                ("timeout", llmTimeout),
                ("unreachable", VoxError.llm("Could not reach the LLM endpoint at http://127.0.0.1:11434/v1/chat/completions")),
                ("empty", VoxError.llm(LLMFailureMessage.emptyResponse)),
            ]
            while true {
                for (_, error) in scenarios {
                    overlay.begin()
                    await pause(0.35)
                    overlay.send(.recordingStarted(at: Date()))
                    await speak(for: 3.2)
                    overlay.send(.transcriptionStarted)
                    await pause(0.7)
                    let refineStart = Date()
                    overlay.send(.modeStarted(name: "prompt", usesLLM: true, model: "phi4-mini:3.8b-q8_0", at: refineStart))
                    await pause(error == nil ? 2.1 : 2.6)
                    overlay.send(.delivered(Delivery(
                        destination: .clipboard,
                        transcriptIsEmpty: false,
                        mode: "prompt",
                        usedLLM: true,
                        modeError: error,
                        modeElapsed: error == llmTimeout ? 60 : Date().timeIntervalSince(refineStart)
                    )))
                    await pause(error == nil ? 2.2 : 5)
                }
            }
        }
    }
}

import AppKit

/// `VOX_HUD_DEMO=1 VOX_HUD_SNAPSHOT_DIR=/some/dir` renders each phase of the
/// real panel to PNG (light and dark) plus a frame sequence of the live
/// waveform, then quits. Uses `cacheDisplay`, so it needs no Screen Recording
/// permission — but that also means the material is drawn without the
/// desktop blurred behind it.
@MainActor
enum HUDSnapshots {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["VOX_HUD_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(on overlay: RecordingOverlayController, into directory: URL) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            @MainActor func pause(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
            @MainActor func capture(_ name: String) {
                guard let view = overlay.panel?.contentView,
                    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
            }
            @MainActor func feed(_ t: Double) {
                let envelope = max(0, sin(t * 5.3)) * 0.7 + max(0, sin(t * 1.7)) * 0.3
                overlay.update(levelDB: -58 + 52 * envelope + Double.random(in: -4...4))
            }
            let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
            for (suffix, appearance) in appearances {
                overlay.begin()
                overlay.panel?.appearance = NSAppearance(named: appearance)
                await pause(0.5)
                capture("1-starting-\(suffix)")
                overlay.send(.recordingStarted(at: Date().addingTimeInterval(-4)))
                var t = 0.0
                for frame in 0..<90 {
                    if frame % 2 == 0 { feed(t); t += 0.0853 }
                    await pause(1.0 / 24)
                    if suffix == "light" { capture(String(format: "frames/%03d", frame)) }
                }
                capture("2-recording-\(suffix)")
                overlay.send(.transcriptionStarted)
                await pause(0.6)
                capture("3-transcribing-\(suffix)")
                overlay.send(.modeStarted(name: "prompt", usesLLM: true, model: "phi4-mini:3.8b-q8_0", at: Date().addingTimeInterval(-1.6)))
                await pause(0.6)
                capture("4-llm-in-flight-\(suffix)")
                overlay.send(.delivered(Delivery(destination: .clipboard, transcriptIsEmpty: false, mode: "prompt", usedLLM: true, modeElapsed: 2.21)))
                await pause(0.6)
                capture("5-done-\(suffix)")

                let failures: [(String, VoxError, TimeInterval)] = [
                    ("6-llm-timeout", .llm("LLM endpoint at http://127.0.0.1:11434/v1/chat/completions didn't respond within 60s"), 60),
                    ("7-llm-unreachable", .llm("Could not reach the LLM endpoint at http://127.0.0.1:11434/v1/chat/completions"), 0.02),
                    ("8-llm-empty", .llm(LLMFailureMessage.emptyResponse), 1.2),
                ]
                for (name, error, elapsed) in failures {
                    overlay.begin()
                    overlay.send(.recordingStarted(at: Date()))
                    overlay.send(.transcriptionStarted)
                    overlay.send(.modeStarted(name: "prompt", usesLLM: true, at: Date()))
                    overlay.send(.delivered(Delivery(destination: .clipboard, transcriptIsEmpty: false, mode: "prompt", usedLLM: true, modeError: error, modeElapsed: elapsed)))
                    await pause(0.6)
                    capture("\(name)-\(suffix)")
                }
                overlay.begin()
                overlay.send(.delivered(Delivery(destination: .clipboard, transcriptIsEmpty: true, mode: "prompt", usedLLM: true)))
                await pause(0.6)
                capture("8b-no-speech-\(suffix)")
                overlay.begin()
                overlay.send(.failed(VoxError(code: .microphone, message: "Could not start the audio engine")))
                await pause(0.6)
                capture("9-mic-failure-\(suffix)")
                overlay.send(.cancelled)
                await pause(0.4)
            }
            NSApp.terminate(nil)
        }
    }
}
