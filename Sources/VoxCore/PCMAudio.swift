import Foundation

/// 16 kHz mono float samples in [-1, 1] — exactly the buffer layout
/// `whisper_full` expects, so nothing between capture and transcription has to
/// touch a file.
public struct PCMAudio: Sendable, Equatable {
    public static let sampleRate: Double = 16_000

    public var samples: [Float]

    public init(samples: [Float]) {
        self.samples = samples
    }

    public var durationSeconds: Double {
        Double(samples.count) / PCMAudio.sampleRate
    }

    public var durationMilliseconds: Int {
        Int((durationSeconds * 1000).rounded())
    }

    public var isEmpty: Bool { samples.isEmpty }

    /// Root-mean-square level in dBFS. `-160` stands in for digital silence.
    public static func levelDB(of samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return -160 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = (Double(sumOfSquares) / Double(samples.count)).squareRoot()
        guard rms > 0 else { return -160 }
        return 20 * log10(rms)
    }
}
