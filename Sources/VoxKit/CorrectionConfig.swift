import Foundation

/// The two ways a user can hand Vox a corrected transcript before (or right
/// after) it leaves Vox's control. Both are off by default: each adds a UI
/// moment, and which one earns its friction is exactly what the logged data
/// is meant to settle.
public struct CorrectionConfig: Codable, Sendable, Equatable {
    public var fixLast: FixLastConfig
    public var preview: PreviewConfig

    public init(fixLast: FixLastConfig = .default, preview: PreviewConfig = .default) {
        self.fixLast = fixLast
        self.preview = preview
    }

    public static let `default` = CorrectionConfig()

    /// Each section is optional on read so a config from before it existed
    /// still decodes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fixLast = try container.decodeIfPresent(FixLastConfig.self, forKey: .fixLast) ?? .default
        preview = try container.decodeIfPresent(PreviewConfig.self, forKey: .preview) ?? .default
    }

    public func validate() throws {
        try fixLast.validate()
        try preview.validate()
    }
}

/// Variant A: a second global hotkey that reopens the most recent transcript
/// for editing, then puts the corrected text back on the clipboard.
public struct FixLastConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Carbon/`CGKeyCode` virtual key code, like `HotkeyConfig.keyCode`.
    public var keyCode: UInt16
    /// Any of `HotkeyConfig.supportedModifiers`.
    public var modifiers: [String]

    public init(
        enabled: Bool = false, keyCode: UInt16 = 49,
        modifiers: [String] = ["control", "option", "shift"]
    ) {
        self.enabled = enabled
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Control+Option+Shift+Space: the record chord plus Shift, so it reads as
    /// "the other thing Vox does" and cannot collide with it (Carbon rejects a
    /// duplicate registration, and the app would otherwise silently lose one).
    /// Not claimed by macOS, and window managers that camp on ⌃⌥ (Rectangle,
    /// Magnet) leave the Shift variants of Space alone.
    public static let `default` = FixLastConfig()

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FixLastConfig()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        keyCode = try container.decodeIfPresent(UInt16.self, forKey: .keyCode) ?? defaults.keyCode
        modifiers =
            try container.decodeIfPresent([String].self, forKey: .modifiers) ?? defaults.modifiers
    }

    /// The chord as a `HotkeyConfig`, for code that registers or displays one.
    public var hotkey: HotkeyConfig {
        HotkeyConfig(keyCode: keyCode, modifiers: modifiers, activation: .toggle, enabled: enabled)
    }

    public func validate() throws {
        try hotkey.validate()
    }

    /// True when both chords are enabled and identical, which Carbon would
    /// refuse for whichever registers second.
    public func collides(with recordHotkey: HotkeyConfig) -> Bool {
        guard enabled, recordHotkey.enabled, keyCode == recordHotkey.keyCode else { return false }
        return Set(modifiers.map { $0.lowercased() })
            == Set(recordHotkey.modifiers.map { $0.lowercased() })
    }
}

/// Variant B: hold the transcript in an editable box for a moment before it
/// is copied or pasted, so an edit made right then is captured as ground truth.
public struct PreviewConfig: Codable, Sendable, Equatable {
    public enum Display: String, Codable, Sendable, CaseIterable {
        /// Every dictation pauses in the preview box.
        case always
        /// Only dictations whose weakest whisper.cpp segment falls below
        /// `confidenceThreshold`; confident ones deliver instantly as today.
        case lowConfidence
    }

    public var enabled: Bool
    /// How long an untouched preview stays up before it commits on its own.
    public var idleTimeoutSeconds: Double
    public var display: Display
    /// Mean per-token log-probability (natural log, so 0 is certain and more
    /// negative is less sure) below which a segment counts as low confidence.
    /// whisper.cpp's own decoder fallback fires at -1.0; -0.6 catches segments
    /// that decoded without a retry but with visibly shaky tokens.
    public var confidenceThreshold: Double

    public init(
        enabled: Bool = false,
        idleTimeoutSeconds: Double = 1.5,
        display: Display = .always,
        confidenceThreshold: Double = -0.6
    ) {
        self.enabled = enabled
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.display = display
        self.confidenceThreshold = confidenceThreshold
    }

    public static let `default` = PreviewConfig()

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PreviewConfig()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        idleTimeoutSeconds =
            try container.decodeIfPresent(Double.self, forKey: .idleTimeoutSeconds)
            ?? defaults.idleTimeoutSeconds
        display = try container.decodeIfPresent(Display.self, forKey: .display) ?? defaults.display
        confidenceThreshold =
            try container.decodeIfPresent(Double.self, forKey: .confidenceThreshold)
            ?? defaults.confidenceThreshold
    }

    public func validate() throws {
        guard idleTimeoutSeconds > 0 else {
            throw VoxError.config("corrections.preview.idle_timeout_seconds must be greater than 0")
        }
        guard confidenceThreshold <= 0 else {
            throw VoxError.config(
                "corrections.preview.confidence_threshold must be 0 or negative (a log-probability)"
            )
        }
    }

    /// Whether a finished dictation should pause in the preview box.
    ///
    /// A confidence-gated preview with no confidence to gate on (an engine
    /// that does not report it, or an empty transcript) shows the box: the
    /// point of gating is to skip dictations known to be good, and unknown is
    /// not known-good.
    public func shouldShow(confidence: TranscriptConfidence?) -> Bool {
        guard enabled else { return false }
        switch display {
        case .always:
            return true
        case .lowConfidence:
            guard let confidence else { return true }
            return confidence.minSegmentLogprob < confidenceThreshold
        }
    }
}

/// How sure whisper.cpp was of what it heard, summarized from its per-token
/// probabilities. Values are mean natural-log probabilities per segment.
public struct TranscriptConfidence: Codable, Sendable, Equatable {
    /// The weakest segment: one bad clause is what makes a transcript worth a
    /// look, however good the rest was.
    public var minSegmentLogprob: Double
    /// Across all segments, weighted by token count.
    public var meanLogprob: Double
    public var segmentCount: Int

    public init(minSegmentLogprob: Double, meanLogprob: Double, segmentCount: Int) {
        self.minSegmentLogprob = minSegmentLogprob
        self.meanLogprob = meanLogprob
        self.segmentCount = segmentCount
    }

    /// `nil` when nothing was decoded, so the caller can tell "no data" apart
    /// from "confident".
    public init?(segmentLogprobs: [(logprob: Double, tokenCount: Int)]) {
        let counted = segmentLogprobs.filter { $0.tokenCount > 0 }
        guard !counted.isEmpty else { return nil }
        let totalTokens = counted.reduce(0) { $0 + $1.tokenCount }
        minSegmentLogprob = counted.map(\.logprob).min() ?? 0
        meanLogprob =
            counted.reduce(0.0) { $0 + $1.logprob * Double($1.tokenCount) } / Double(totalTokens)
        segmentCount = counted.count
    }
}
