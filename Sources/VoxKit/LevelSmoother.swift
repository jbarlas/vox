import Foundation

/// Turns the capture tap's coarse level readings (one per ~4096-frame buffer,
/// ~85–93ms apart at 48/44.1kHz) into a smooth, display-rate signal for the HUD
/// waveform.
///
/// `ingest` is cheap and called whenever a reading arrives; `advance` is
/// called once per rendered frame with the frame's timestamp. Nothing here
/// publishes or allocates per frame, so driving it from a 60fps timeline
/// costs a handful of multiplies.
public struct LevelSmoother: Sendable {
    public static let floorDB = -60.0

    /// Bars in the scrolling history, oldest first.
    public let capacity: Int
    /// How often a new bar scrolls in.
    public let sampleInterval: TimeInterval
    /// Time constants for the attack/release envelope: rise quickly so a
    /// syllable registers immediately, fall slowly so the bars don't flicker
    /// between tap callbacks.
    public var attack: TimeInterval = 0.035
    public var release: TimeInterval = 0.16
    /// A reading holds for about one tap interval before decaying, so the
    /// envelope bridges the gap until the next one arrives.
    public var hold: TimeInterval = 0.1

    /// Smoothed level, 0...1.
    public private(set) var level: Double = 0
    /// Fraction (0..<1) of the way to the next bar, for sub-bar scrolling.
    public private(set) var scrollPhase: Double = 0

    private var target: Double = 0
    private var targetAge: TimeInterval = 0
    private var ring: [Double]
    private var head = 0
    private var lastFrame: TimeInterval?

    public init(capacity: Int = 44, sampleInterval: TimeInterval = 1.0 / 24.0) {
        precondition(capacity > 0 && sampleInterval > 0)
        self.capacity = capacity
        self.sampleInterval = sampleInterval
        self.ring = Array(repeating: 0, count: capacity)
    }

    /// dBFS is logarithmic and speech mostly sits between -50 and -10, so
    /// the bottom is clamped and a gentle curve lifts quiet speech into view.
    public static func normalize(db: Double) -> Double {
        guard db.isFinite else { return 0 }
        let linear = min(1, max(0, (db - floorDB) / -floorDB))
        return pow(linear, 1.35)
    }

    public mutating func ingest(db: Double) {
        target = Self.normalize(db: db)
        targetAge = 0
    }

    /// Advances the envelope to `time` (seconds, any monotonic clock).
    /// Gaps longer than a few frames — the HUD was hidden, or the main
    /// thread stalled — are clamped so the meter never lurches.
    public mutating func advance(to time: TimeInterval) {
        let dt = lastFrame.map { min(max(0, time - $0), 0.1) } ?? 0
        lastFrame = time
        advance(by: dt)
    }

    public mutating func advance(by dt: TimeInterval) {
        guard dt > 0 else { return }
        targetAge += dt
        if targetAge > hold {
            // Let a held reading fade toward silence when no new one arrives.
            target *= exp(-(dt) / release)
        }
        let tau = target > level ? attack : release
        level += (target - level) * (1 - exp(-dt / tau))

        var progress = scrollPhase + dt / sampleInterval
        while progress >= 1 {
            ring[head] = level
            head = (head + 1) % capacity
            progress -= 1
        }
        scrollPhase = progress
    }

    /// The history, oldest to newest.
    public var samples: [Double] {
        Array(ring[head...] + ring[..<head])
    }

    /// Calls `body` for each history sample, oldest first, without
    /// allocating — the render path uses this every frame.
    public func forEachSample(_ body: (Int, Double) -> Void) {
        for index in 0..<capacity {
            body(index, ring[(head + index) % capacity])
        }
    }

    public mutating func reset() {
        level = 0
        target = 0
        targetAge = 0
        scrollPhase = 0
        head = 0
        lastFrame = nil
        for index in ring.indices { ring[index] = 0 }
    }
}
