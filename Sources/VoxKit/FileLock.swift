import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Serializes a read-modify-write cycle on a shared file across processes.
///
/// `config.json` and `sessions.json` are both written by the menu bar app and
/// by every `vox` invocation. An atomic write keeps either file from ever being
/// half-written, but it cannot stop two processes from loading the same
/// snapshot, mutating their own copy, and writing back — whoever writes last
/// wins and the other change is gone. An advisory `flock(2)` on a sidecar lock
/// file is what actually orders those cycles; an in-process lock cannot, since
/// the contenders are different processes.
///
/// Nesting is safe: a `withLock` inside another `withLock` for the same path on
/// the same thread reuses the outer lock rather than blocking on itself (each
/// `open` produces an independent open file description, so a second `flock`
/// would deadlock against the first).
public enum FileLock {
    private static let registryLock = NSLock()
    private static var gates: [String: NSRecursiveLock] = [:]

    /// Runs `body` while holding an exclusive lock on `url`.
    ///
    /// A lock that cannot be taken (read-only directory, filesystem without
    /// `flock` support) is not fatal: `body` still runs, unserialized, because
    /// refusing to save is worse than a rare lost write.
    public static func withLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        let path = url.path
        let gate = gate(for: path)
        gate.lock()
        defer { gate.unlock() }

        let key = "vox.filelock.\(path)"
        let threadStorage = Thread.current.threadDictionary
        let depth = (threadStorage[key] as? Int) ?? 0
        threadStorage[key] = depth + 1
        defer {
            if depth == 0 {
                threadStorage.removeObject(forKey: key)
            } else {
                threadStorage[key] = depth
            }
        }

        guard depth == 0, let descriptor = openLockFile(at: url) else {
            return try body()
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        return try body()
    }

    private static func gate(for path: String) -> NSRecursiveLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = gates[path] { return existing }
        let created = NSRecursiveLock()
        gates[path] = created
        return created
    }

    /// Opens (creating if needed) the lock file and blocks until the exclusive
    /// lock is held. Returns `nil` when locking is unavailable.
    private static func openLockFile(at url: URL) -> Int32? {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        while flock(descriptor, LOCK_EX) != 0 {
            // A signal can interrupt the wait; anything else means locking is
            // not usable on this file at all.
            guard errno == EINTR else {
                close(descriptor)
                return nil
            }
        }
        return descriptor
    }
}
