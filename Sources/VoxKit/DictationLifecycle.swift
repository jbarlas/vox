import Foundation

/// Keeps a quit request pending until a dictation has delivered its output.
/// The caller keeps its event loop running so recording can still be stopped
/// normally while shutdown is pending.
@MainActor
public final class DictationLifecycle {
    private var task: Task<Void, Never>?
    private var terminationRequested = false
    private var onReadyToTerminate: (() -> Void)?

    public init() {}

    public var canStart: Bool { task == nil && !terminationRequested }

    @discardableResult
    public func start(_ operation: @escaping @MainActor () async -> Void) -> Bool {
        guard canStart else { return false }
        task = Task {
            await operation()
            task = nil
            let completion = onReadyToTerminate
            onReadyToTerminate = nil
            completion?()
        }
        return true
    }

    /// Returns true when the caller can quit immediately. Otherwise it must
    /// defer quitting until `whenReady` runs. Repeated requests do not cancel
    /// the active operation or schedule multiple termination callbacks.
    public func requestTermination(whenReady: @escaping () -> Void) -> Bool {
        terminationRequested = true
        guard task != nil else { return true }
        onReadyToTerminate = whenReady
        return false
    }
}
