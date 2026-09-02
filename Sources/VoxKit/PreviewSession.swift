import Foundation

/// The lifecycle of one editable transcript box, for both correction surfaces:
/// the pre-paste preview (which arms an idle timer that commits the untouched
/// text) and the fix-last editor (which never times out).
///
/// Pure state: the caller owns the actual timer and window and performs the
/// returned `Action`s, which is what keeps the rules testable without AppKit.
public struct PreviewSession: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Shown, untouched; the idle timer (if any) is running.
        case pending
        /// The user typed. Only an explicit confirm or cancel closes it now.
        case editing
        case closed
    }

    public enum CommitReason: Equatable, Sendable {
        case idleTimeout
        case confirmed
    }

    public enum Action: Equatable, Sendable {
        case armIdleTimer(seconds: Double)
        case cancelIdleTimer
        case commit(Commit)
        case dismiss
    }

    public struct Commit: Equatable, Sendable {
        public var text: String
        public var reason: CommitReason
        /// True when `text` differs from what was shown (beyond whitespace).
        public var changed: Bool

        public var telemetryEvent: CorrectionTelemetry.Event {
            switch (reason, changed) {
            case (.idleTimeout, _): return .autoCommitted
            case (.confirmed, true): return .corrected
            case (.confirmed, false): return .confirmedUnchanged
            }
        }
    }

    public let originalText: String
    /// `nil` never auto-commits (the fix-last editor).
    public let idleTimeoutSeconds: Double?
    public private(set) var currentText: String
    public private(set) var phase: Phase = .pending

    public init(text: String, idleTimeoutSeconds: Double?) {
        self.originalText = text
        self.currentText = text
        self.idleTimeoutSeconds = idleTimeoutSeconds
    }

    public var isClosed: Bool { phase == .closed }

    public var hasChanges: Bool {
        CorrectionRecord.isMeaningfulChange(from: originalText, to: currentText)
    }

    /// Call once the box is on screen.
    public mutating func start() -> [Action] {
        guard phase == .pending, let idleTimeoutSeconds else { return [] }
        return [.armIdleTimer(seconds: idleTimeoutSeconds)]
    }

    /// Any keystroke in the text — even one that leaves it equal to the
    /// original — means the user is looking at it, so the timer must stop.
    public mutating func textDidChange(_ text: String) -> [Action] {
        guard phase != .closed else { return [] }
        currentText = text
        guard phase == .pending else { return [] }
        phase = .editing
        return idleTimeoutSeconds == nil ? [] : [.cancelIdleTimer]
    }

    /// A timer that fires after the user started typing (a race the caller's
    /// cancel lost) is ignored: an edit in progress must never be pasted.
    public mutating func idleTimerFired() -> [Action] {
        guard phase == .pending else { return [] }
        phase = .closed
        return [.commit(Commit(text: originalText, reason: .idleTimeout, changed: false))]
    }

    /// Return. An edit that emptied the box is treated as a cancel: pasting
    /// nothing is never what the user meant.
    public mutating func confirm() -> [Action] {
        guard phase != .closed else { return [] }
        let wasPending = phase == .pending
        phase = .closed
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return (wasPending && idleTimeoutSeconds != nil ? [.cancelIdleTimer] : []) + [.dismiss]
        }
        let commit = Commit(text: trimmed, reason: .confirmed, changed: hasChanges)
        return (wasPending && idleTimeoutSeconds != nil ? [.cancelIdleTimer] : []) + [.commit(commit)]
    }

    /// Escape.
    public mutating func cancel() -> [Action] {
        guard phase != .closed else { return [] }
        let wasPending = phase == .pending
        phase = .closed
        return (wasPending && idleTimeoutSeconds != nil ? [.cancelIdleTimer] : []) + [.dismiss]
    }
}
