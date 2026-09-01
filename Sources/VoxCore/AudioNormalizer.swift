import AVFoundation
import Foundation
import VoxKit

/// Converts arbitrary audio files into the 16 kHz mono float buffer the
/// transcriber consumes.
///
/// Live microphone capture does not go through here — `AudioCapture` already
/// converts in-flight. This path exists for `vox transcribe <file>`, which is
/// also how the pipeline is exercised without a microphone.
public enum AudioNormalizer {
    /// Decodes with AVFoundation, falling back to an `ffmpeg` shellout for
    /// containers/codecs AVFoundation refuses (ffmpeg is therefore optional,
    /// not a hard dependency).
    public static func pcm(fromFileAt url: URL) throws -> PCMAudio {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VoxError(code: .audio, message: "No such audio file", detail: url.path)
        }
        if let audio = try? decodeWithAVFoundation(url: url) {
            return audio
        }
        return try decodeWithFFmpeg(url: url)
    }

    static func decodeWithAVFoundation(url: URL) throws -> PCMAudio {
        let file = try AVAudioFile(forReading: url)
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: PCMAudio.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat)
        else {
            throw VoxError(code: .audio, message: "Could not build a 16 kHz mono converter", detail: url.path)
        }

        let frameCapacity: AVAudioFrameCount = 16_384
        guard
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: frameCapacity)
        else {
            throw VoxError(code: .audio, message: "Could not allocate a decode buffer", detail: url.path)
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * PCMAudio.sampleRate / file.processingFormat.sampleRate))

        while true {
            try file.read(into: inputBuffer, frameCount: frameCapacity)
            if inputBuffer.frameLength == 0 { break }
            let ratio = targetFormat.sampleRate / file.processingFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                throw VoxError(code: .audio, message: "Could not allocate a resample buffer", detail: url.path)
            }
            var consumed = false
            var conversionError: NSError?
            converter.convert(to: outputBuffer, error: &conversionError) { _, statusPointer in
                if consumed {
                    statusPointer.pointee = .noDataNow
                    return nil
                }
                consumed = true
                statusPointer.pointee = .haveData
                return inputBuffer
            }
            if let conversionError {
                throw VoxError(
                    code: .audio,
                    message: "Could not resample \(url.lastPathComponent)",
                    detail: conversionError.localizedDescription
                )
            }
            guard let channel = outputBuffer.floatChannelData?[0] else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
        }

        guard !samples.isEmpty else {
            throw VoxError(code: .audio, message: "Decoded no audio from \(url.lastPathComponent)")
        }
        return PCMAudio(samples: samples)
    }

    static func decodeWithFFmpeg(url: URL) throws -> PCMAudio {
        guard let ffmpeg = locateFFmpeg() else {
            throw VoxError(
                code: .audio,
                message: "Could not decode \(url.lastPathComponent)",
                detail: "AVFoundation rejected the file and ffmpeg was not found on PATH."
            )
        }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-nostdin", "-loglevel", "error",
            "-i", url.path,
            "-f", "f32le", "-acodec", "pcm_f32le",
            "-ac", "1", "-ar", String(Int(PCMAudio.sampleRate)),
            "-",
        ]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw VoxError(
                code: .audio,
                message: "Could not launch ffmpeg",
                detail: error.localizedDescription
            )
        }
        // Both pipes are drained concurrently: raw PCM on stdout is large, and
        // reading it to the end first would let a chatty stderr fill its buffer
        // and wedge ffmpeg before it ever finishes writing audio.
        let errorData = UnsafeSendableBox<Data>(Data())
        let errorDrained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            errorData.value = errorPipe.fileHandleForReading.readDataToEndOfFile()
            errorDrained.signal()
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        errorDrained.wait()
        let errorText = String(data: errorData.value, encoding: .utf8)
        process.waitUntilExit()

        guard process.terminationStatus == 0, !data.isEmpty else {
            throw VoxError(
                code: .audio,
                message: "ffmpeg could not decode \(url.lastPathComponent)",
                detail: errorText
            )
        }
        let samples = data.withUnsafeBytes { raw -> [Float] in
            Array(raw.bindMemory(to: Float.self))
        }
        return PCMAudio(samples: samples)
    }

    /// Handoff of a value between a drain queue and the caller, ordered by the
    /// semaphore rather than by the type system.
    private final class UnsafeSendableBox<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    static func locateFFmpeg() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":") {
            let candidate = String(directory) + "/ffmpeg"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Writes a 16-bit mono WAV, used by `--save-audio` when a transcript needs
    /// to be reproduced or filed against a bug.
    public static func writeWAV(_ audio: PCMAudio, to url: URL) throws {
        var data = Data()
        let sampleRate = UInt32(PCMAudio.sampleRate)
        let byteRate = sampleRate * 2
        let dataSize = UInt32(audio.samples.count * 2)

        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(sampleRate)
        append(byteRate)
        append(UInt16(2))  // block align
        append(UInt16(16))  // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for sample in audio.samples {
            append(Int16(max(-1, min(1, sample)) * 32_767))
        }
        try data.write(to: url, options: .atomic)
    }
}
