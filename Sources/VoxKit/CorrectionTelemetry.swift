import Foundation

/// Local-only counters for how often each correction surface is shown and how
/// often it actually yields a correction, so the two variants can be compared
/// before deciding which one to keep. Nothing here leaves the machine.
public struct CorrectionTelemetry: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public struct VariantCounts: Codable, Sendable, Equatable {
        /// Fix-last: the hotkey opened a transcript. Preview: the box was shown.
        public var invocations: Int
        /// Confirmed with a text change (a `CorrectionRecord` was written).
        public var corrections: Int
        /// Confirmed with the text untouched. For the preview this is an
        /// explicit Return; the idle timeout is counted separately.
        public var confirmedUnchanged: Int
        /// Closed without committing (Escape).
        public var cancelled: Int
        /// Preview only: the idle window elapsed and the text went out as-is.
        public var autoCommits: Int
        /// Fix-last only: the hotkey was pressed with no transcript to fix.
        public var emptyInvocations: Int

        public init(
            invocations: Int = 0,
            corrections: Int = 0,
            confirmedUnchanged: Int = 0,
            cancelled: Int = 0,
            autoCommits: Int = 0,
            emptyInvocations: Int = 0
        ) {
            self.invocations = invocations
            self.corrections = corrections
            self.confirmedUnchanged = confirmedUnchanged
            self.cancelled = cancelled
            self.autoCommits = autoCommits
            self.emptyInvocations = emptyInvocations
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            invocations = try container.decodeIfPresent(Int.self, forKey: .invocations) ?? 0
            corrections = try container.decodeIfPresent(Int.self, forKey: .corrections) ?? 0
            confirmedUnchanged = try container.decodeIfPresent(Int.self, forKey: .confirmedUnchanged) ?? 0
            cancelled = try container.decodeIfPresent(Int.self, forKey: .cancelled) ?? 0
            autoCommits = try container.decodeIfPresent(Int.self, forKey: .autoCommits) ?? 0
            emptyInvocations = try container.decodeIfPresent(Int.self, forKey: .emptyInvocations) ?? 0
        }
    }

    public enum Event: String, Codable, Sendable, CaseIterable {
        case invoked
        case corrected
        case confirmedUnchanged
        case cancelled
        case autoCommitted
        case invokedEmpty
    }

    public var schemaVersion: Int
    public var fixLast: VariantCounts
    public var preview: VariantCounts
    public var updatedAt: Date?

    public init(
        fixLast: VariantCounts = VariantCounts(), preview: VariantCounts = VariantCounts(),
        updatedAt: Date? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.fixLast = fixLast
        self.preview = preview
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion =
            try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        fixLast = try container.decodeIfPresent(VariantCounts.self, forKey: .fixLast) ?? VariantCounts()
        preview = try container.decodeIfPresent(VariantCounts.self, forKey: .preview) ?? VariantCounts()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public subscript(variant: CorrectionVariant) -> VariantCounts {
        get {
            switch variant {
            case .fixLast: return fixLast
            case .preview: return preview
            }
        }
        set {
            switch variant {
            case .fixLast: fixLast = newValue
            case .preview: preview = newValue
            }
        }
    }

    public mutating func record(
        _ event: Event, for variant: CorrectionVariant, at date: Date = Date()
    ) {
        switch event {
        case .invoked: self[variant].invocations += 1
        case .corrected: self[variant].corrections += 1
        case .confirmedUnchanged: self[variant].confirmedUnchanged += 1
        case .cancelled: self[variant].cancelled += 1
        case .autoCommitted: self[variant].autoCommits += 1
        case .invokedEmpty: self[variant].emptyInvocations += 1
        }
        updatedAt = date
    }
}

/// `corrections/telemetry.json`, updated under the same cross-process lock
/// discipline as `sessions.json`. Every write is best-effort from the caller's
/// point of view: a counter must never break a dictation or a correction.
public final class CorrectionTelemetryStore {
    private let paths: VoxPaths
    private let lock = NSLock()

    public init(paths: VoxPaths = VoxPaths()) {
        self.paths = paths
    }

    public func load() -> CorrectionTelemetry {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    public func record(
        _ event: CorrectionTelemetry.Event, for variant: CorrectionVariant, at date: Date = Date()
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(
            at: paths.correctionsDirectory, withIntermediateDirectories: true)
        try FileLock.withLock(at: paths.correctionTelemetryLockFile) {
            var telemetry = loadLocked()
            telemetry.record(event, for: variant, at: date)
            let data = try VoxJSON.encoder(pretty: true).encode(telemetry)
            try data.write(to: paths.correctionTelemetryFile, options: .atomic)
        }
    }

    private func loadLocked() -> CorrectionTelemetry {
        guard let data = try? Data(contentsOf: paths.correctionTelemetryFile) else {
            return CorrectionTelemetry()
        }
        return (try? VoxJSON.decoder().decode(CorrectionTelemetry.self, from: data))
            ?? CorrectionTelemetry()
    }
}
