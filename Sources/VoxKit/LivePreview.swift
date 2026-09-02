import Foundation

/// The optional live preview shown by the menu bar app while recording: rolling
/// chunked inference over the audio captured so far, rendered as low-confidence
/// text so the user can see dictation is working before the recording ends.
///
/// Purely cosmetic. The preview is discarded when recording stops and the
/// single full-pass transcript replaces it; nothing here ever reaches a mode,
/// the output router, session history, or the CLI's JSON envelope.
public struct LivePreviewConfig: Codable, Sendable, Equatable {
    /// Off by default: chunked inference is noticeably less accurate than the
    /// full pass that replaces it, and the extra model costs CPU/GPU while the
    /// user is talking.
    public var enabled: Bool
    /// The model used for chunk re-inference. Independent of the main `model`
    /// so a fast `tiny.en`/`base.en` can preview while a large model does the
    /// accurate final pass; the two are loaded in separate whisper contexts.
    public var model: String
    /// How much trailing audio each preview inference sees. Whisper's encoder
    /// pads everything to 30 s internally, so shorter windows are cheaper but
    /// cut more words at the boundary; ~8 s is a reasonable middle.
    public var windowSeconds: Double
    /// Minimum spacing between two preview inferences. Inference never
    /// overlaps itself regardless; this only stops a fast model from spinning.
    public var intervalSeconds: Double

    public init(
        enabled: Bool = false,
        model: String = "base.en",
        windowSeconds: Double = 8,
        intervalSeconds: Double = 1.5
    ) {
        self.enabled = enabled
        self.model = model
        self.windowSeconds = windowSeconds
        self.intervalSeconds = intervalSeconds
    }

    public static let `default` = LivePreviewConfig()

    public var resolvedModel: WhisperModel? {
        ModelCatalog.model(id: model)
    }

    public func validate() throws {
        guard ModelCatalog.model(id: model) != nil else {
            throw VoxError.config(
                "Unknown live_preview.model '\(model)'",
                detail: "Known models: \(ModelCatalog.all.map(\.id).joined(separator: ", "))"
            )
        }
        guard windowSeconds >= 1, windowSeconds <= 30 else {
            throw VoxError.config("live_preview.window_seconds must be between 1 and 30")
        }
        guard intervalSeconds >= 0.25, intervalSeconds <= 30 else {
            throw VoxError.config("live_preview.interval_seconds must be between 0.25 and 30")
        }
    }
}

/// What the UI renders: text from windows that have already scrolled out of
/// view is frozen, the current window's text is re-transcribed on every tick
/// and replaced wholesale.
public struct LivePreviewSnapshot: Sendable, Equatable {
    /// Text from completed chunks; no longer changes.
    public var committed: String
    /// The current chunk's most recent decode; replaced on the next result.
    public var volatile: String

    public init(committed: String = "", volatile: String = "") {
        self.committed = committed
        self.volatile = volatile
    }

    public var text: String {
        [committed, volatile].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var isEmpty: Bool { committed.isEmpty && volatile.isEmpty }
}

/// One preview inference the caller should run, as a half-open sample range
/// into the recording buffer. `generation` guards against results from a
/// previous recording being applied to the current one.
public struct LivePreviewRequest: Sendable, Equatable {
    public let id: Int
    public let generation: Int
    public let sampleRange: Range<Int>
    /// True when this window is full: its result is frozen into `committed`
    /// and the next chunk starts where it ended.
    public let commitsChunk: Bool

    public var sampleCount: Int { sampleRange.count }
}

/// Decides *when* to run preview inference and *what* to show afterwards.
/// Pure state — the caller owns the audio buffer, the clock, and the engine,
/// which is what lets the chunking rules be unit-tested off-Mac.
///
/// Lifecycle: `start()` → repeated `audioDidGrow` / `nextRequest(now:)` /
/// `complete(_:text:)` → `stop()`. `stop()` drops the preview and refuses
/// further requests: from that point only the full pass matters.
public struct LivePreviewScheduler: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case recording
        case stopped
    }

    public let sampleRate: Double
    public let windowSamples: Int
    public let intervalSeconds: Double
    /// Below this much unseen audio, another decode would only repeat the
    /// last one. Also the floor for the very first request: whisper.cpp
    /// reliably decodes garbage under a few hundred milliseconds.
    public let minimumNewSamples: Int

    public private(set) var phase: Phase = .idle
    public private(set) var snapshot = LivePreviewSnapshot()
    public private(set) var inFlight: LivePreviewRequest?
    /// Completed inferences whose result was applied to the snapshot.
    public private(set) var completedRequestCount = 0

    private var generation = 0
    private var nextRequestID = 0
    private var totalSamples = 0
    /// Where the current (volatile) chunk begins.
    private var chunkStart = 0
    private var lastRequestAt: Date?
    /// End of the last window that actually produced a result, so a failed
    /// decode is retried over the same audio rather than skipped.
    private var lastDecodedEnd = 0

    public init(
        config: LivePreviewConfig,
        sampleRate: Double,
        minimumNewSeconds: Double = 0.5
    ) {
        self.sampleRate = sampleRate
        self.windowSamples = max(1, Int(config.windowSeconds * sampleRate))
        self.intervalSeconds = config.intervalSeconds
        self.minimumNewSamples = max(1, Int(minimumNewSeconds * sampleRate))
    }

    public var isRecording: Bool { phase == .recording }

    /// Begins a new recording. Any result still in flight from the previous
    /// one belongs to an older generation and will be ignored.
    public mutating func start() {
        generation += 1
        phase = .recording
        snapshot = LivePreviewSnapshot()
        inFlight = nil
        totalSamples = 0
        chunkStart = 0
        lastRequestAt = nil
        lastDecodedEnd = 0
        completedRequestCount = 0
    }

    /// The recording ended: the preview is discarded here rather than kept as
    /// a fallback, so the only text that can ever leave the pipeline is the
    /// full-pass result.
    public mutating func stop() {
        phase = .stopped
        snapshot = LivePreviewSnapshot()
        inFlight = nil
    }

    /// The capture buffer now holds `totalSamples` samples.
    public mutating func audioDidGrow(totalSamples: Int) {
        guard phase == .recording else { return }
        self.totalSamples = max(self.totalSamples, totalSamples)
    }

    /// The window to transcribe now, or nil when nothing is due: not
    /// recording, a request is still running, the interval has not elapsed,
    /// or too little new audio has arrived.
    public mutating func nextRequest(now: Date) -> LivePreviewRequest? {
        guard phase == .recording, inFlight == nil else { return nil }
        if let lastRequestAt, now.timeIntervalSince(lastRequestAt) < intervalSeconds {
            return nil
        }
        guard totalSamples - lastDecodedEnd >= minimumNewSamples else { return nil }
        guard totalSamples - chunkStart >= minimumNewSamples else { return nil }

        let chunkLength = totalSamples - chunkStart
        let commits = chunkLength >= windowSamples
        let end = commits ? chunkStart + windowSamples : totalSamples
        let request = LivePreviewRequest(
            id: nextRequestID,
            generation: generation,
            sampleRange: chunkStart..<end,
            commitsChunk: commits
        )
        nextRequestID += 1
        inFlight = request
        lastRequestAt = now
        return request
    }

    /// Applies an inference result. Returns the new snapshot when it changed,
    /// nil when the result was stale (older generation, already superseded,
    /// or arriving after `stop()`).
    @discardableResult
    public mutating func complete(_ request: LivePreviewRequest, text rawText: String) -> LivePreviewSnapshot? {
        guard phase == .recording, let inFlight, inFlight == request, request.generation == generation else {
            if self.inFlight == request { self.inFlight = nil }
            return nil
        }
        self.inFlight = nil
        completedRequestCount += 1
        lastDecodedEnd = request.sampleRange.upperBound
        let text = LivePreviewText.clean(rawText)
        if request.commitsChunk {
            snapshot.committed = LivePreviewText.join(snapshot.committed, text)
            snapshot.volatile = ""
            chunkStart = request.sampleRange.upperBound
        } else {
            snapshot.volatile = text
        }
        return snapshot
    }

    /// A failed inference: clear the slot so the next tick tries again, keep
    /// whatever was already on screen.
    public mutating func fail(_ request: LivePreviewRequest) {
        guard inFlight == request else { return }
        inFlight = nil
    }
}

/// Text hygiene for chunk output. Whisper decodes silence and cut-off words
/// into bracketed markers (`[BLANK_AUDIO]`, `(music)`) and stray punctuation
/// that would flicker across the preview; the final pass never sees this.
public enum LivePreviewText {
    public static func clean(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            switch character {
            case "[", "(":
                depth += 1
            case "]", ")":
                depth = max(0, depth - 1)
            default:
                if depth == 0 { result.append(character) }
            }
        }
        let collapsed = result
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        // A chunk of pure silence often comes back as a lone "." or "…".
        guard collapsed.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return collapsed
    }

    public static func join(_ lhs: String, _ rhs: String) -> String {
        switch (lhs.isEmpty, rhs.isEmpty) {
        case (true, _): return rhs
        case (_, true): return lhs
        default: return lhs + " " + rhs
        }
    }
}
