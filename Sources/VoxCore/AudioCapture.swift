import AVFoundation
import Foundation
import VoxKit

public struct CaptureOutput: Sendable {
    public let audio: PCMAudio
    public let stopReason: StopReason
}

/// Microphone capture that hands back exactly what the transcriber needs.
///
/// The input tap is converted to 16 kHz mono float in-flight by
/// `AVAudioConverter`, so there is no intermediate file and no ffmpeg process
/// on the hot path.
public final class AudioCapture: NSObject {
    public enum Event: Sendable {
        /// Instantaneous input level in dBFS, for the menu bar meter.
        case level(Double)
    }

    private let config: RecordingConfig
    private let engine = AVAudioEngine()
    private let state = CaptureState()
    private var converter: AVAudioConverter?

    public init(config: RecordingConfig) {
        self.config = config
        super.init()
    }

    /// Whether access is already granted, without prompting.
    public static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Asks for microphone access, prompting on first run.
    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Stops an in-flight recording. Safe to call from any thread; this is what
    /// a hotkey release or a second toggle press calls.
    public func stop() {
        state.requestStop(reason: .manual)
    }

    public var isRecording: Bool { state.isRunning }

    /// Records until silence, the deadline, or `stop()`.
    ///
    /// `timeout` overrides `RecordingConfig.maxDurationSeconds` so an agent can
    /// bound how long it waits without editing config.
    public func record(
        timeout: Double? = nil,
        onEvent: (@Sendable (Event) -> Void)? = nil
    ) async throws -> CaptureOutput {
        guard await AudioCapture.requestPermission() else {
            throw VoxError(
                code: .permission,
                message: "Microphone access was denied",
                detail: "Grant access in System Settings → Privacy & Security → Microphone."
            )
        }
        guard !state.isRunning else {
            throw VoxError(code: .microphone, message: "A recording is already in progress")
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoxError(
                code: .microphone,
                message: "No usable audio input device was found",
                detail: "Input format reported \(inputFormat.sampleRate) Hz / \(inputFormat.channelCount) ch."
            )
        }
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: PCMAudio.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else {
            throw VoxError(
                code: .audio,
                message: "Could not build a 16 kHz mono converter for the input device",
                detail: "Input format: \(inputFormat)"
            )
        }
        self.converter = converter

        let maxDuration = timeout ?? config.maxDurationSeconds
        let silenceTimeout = config.silenceTimeoutSeconds
        let silenceThreshold = config.silenceThresholdDB

        state.begin()
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converted = self.convert(buffer, using: converter, to: targetFormat) else {
                return
            }
            let level = PCMAudio.levelDB(of: converted[...])
            onEvent?(.level(level))
            self.state.append(
                samples: converted,
                level: level,
                silenceThreshold: silenceThreshold,
                silenceTimeout: silenceTimeout,
                maxDuration: maxDuration
            )
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            state.end()
            throw VoxError(
                code: .microphone,
                message: "Could not start the audio engine",
                detail: error.localizedDescription
            )
        }

        let reason = await state.waitForStop()
        engine.stop()
        inputNode.removeTap(onBus: 0)
        let samples = state.drain()
        state.end()

        return CaptureOutput(audio: PCMAudio(samples: samples), stopReason: reason)
    }

    private func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> [Float]? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, statusPointer in
            if consumed {
                statusPointer.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPointer.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// All mutable capture state lives here so the audio tap (a real-time thread)
/// and the awaiting caller never touch the same memory unguarded.
private final class CaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var running = false
    private var stopReason: StopReason?
    private var continuation: CheckedContinuation<StopReason, Never>?
    private var startedAt = Date()
    private var lastVoiceAt: Date?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func begin() {
        lock.lock()
        defer { lock.unlock() }
        samples = []
        running = true
        stopReason = nil
        startedAt = Date()
        lastVoiceAt = nil
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        running = false
        continuation = nil
    }

    func append(
        samples newSamples: [Float],
        level: Double,
        silenceThreshold: Double,
        silenceTimeout: Double?,
        maxDuration: Double
    ) {
        lock.lock()
        guard running, stopReason == nil else {
            lock.unlock()
            return
        }
        samples.append(contentsOf: newSamples)
        let now = Date()
        if level > silenceThreshold {
            lastVoiceAt = now
        }
        var reason: StopReason?
        if now.timeIntervalSince(startedAt) >= maxDuration {
            reason = .maxDuration
        } else if let silenceTimeout, let lastVoiceAt,
            now.timeIntervalSince(lastVoiceAt) >= silenceTimeout
        {
            // Only after speech has been heard: otherwise a slow start would
            // cut the recording off before the user began talking.
            reason = .silence
        }
        let resumed = reason.flatMap { finishLocked(reason: $0) }
        lock.unlock()
        resumed?()
    }

    func requestStop(reason: StopReason) {
        lock.lock()
        let resumed = finishLocked(reason: reason)
        lock.unlock()
        resumed?()
    }

    func waitForStop() async -> StopReason {
        await withCheckedContinuation { (continuation: CheckedContinuation<StopReason, Never>) in
            lock.lock()
            if let reason = stopReason {
                lock.unlock()
                continuation.resume(returning: reason)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let result = samples
        samples = []
        return result
    }

    /// Must be called with the lock held; returns a closure to run after
    /// unlocking so a continuation never resumes while holding the lock.
    private func finishLocked(reason: StopReason) -> (() -> Void)? {
        guard running, stopReason == nil else { return nil }
        stopReason = reason
        guard let continuation else { return nil }
        self.continuation = nil
        return { continuation.resume(returning: reason) }
    }
}
