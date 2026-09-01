import XCTest

@testable import VoxKit

/// The races these guard against (`vox config set` against a Settings save, two
/// dictations finishing together) are cross-process, and `flock` is what orders
/// those; a test can only exercise the in-process half plus the invariants the
/// helper has to hold for the cross-process half to work at all.
final class FileLockTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vox-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCriticalSectionsNeverOverlap() throws {
        let lockFile = directory.appendingPathComponent("overlap.lock")
        let counter = Counter()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            try? FileLock.withLock(at: lockFile) {
                XCTAssertEqual(counter.enter(), 1)
                Thread.sleep(forTimeInterval: 0.002)
                counter.leave()
            }
        }
        XCTAssertEqual(counter.maximumConcurrent, 1)
    }

    /// `open` gives each acquisition its own open file description, so a second
    /// `flock` from the same thread would block on the first one forever.
    func testNestedAcquisitionOnTheSameThreadDoesNotDeadlock() throws {
        let lockFile = directory.appendingPathComponent("nested.lock")
        let reached = try FileLock.withLock(at: lockFile) {
            try FileLock.withLock(at: lockFile) { true }
        }
        XCTAssertTrue(reached)
    }

    func testLockFileIsCreatedAlongsideTheDocument() throws {
        let lockFile = directory.appendingPathComponent("nested/created.lock")
        try FileLock.withLock(at: lockFile) {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockFile.path))
    }

    func testBodyStillRunsWhenTheLockCannotBeTaken() throws {
        // A path that cannot be created at all: locking is unavailable, but
        // refusing to save would be worse than an unserialized write.
        let unusable = URL(fileURLWithPath: "/proc/vox-nonexistent/config.json.lock")
        var ran = false
        try FileLock.withLock(at: unusable) { ran = true }
        XCTAssertTrue(ran)
    }

    func testConcurrentConfigUpdatesDoNotLoseSettings() throws {
        let store = ConfigStore(paths: VoxPaths(supportDirectory: directory))
        try store.save(VoxConfig())
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            _ = try? store.update { config in
                config.vocabulary.append("word\(index)")
            }
        }
        XCTAssertEqual(Set(try store.load().vocabulary).count, 8)
    }

    func testConcurrentHistoryAppendsKeepEveryEntry() throws {
        let history = SessionHistory(paths: VoxPaths(supportDirectory: directory), limit: nil)
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            try? history.append(
                SessionEntry(transcript: "entry \(index)", mode: "raw", model: "tiny.en")
            )
        }
        XCTAssertEqual(try history.entries().count, 8)
    }
}

private final class Counter {
    private let lock = NSLock()
    private var current = 0
    private var maximum = 0

    func enter() -> Int {
        lock.lock()
        defer { lock.unlock() }
        current += 1
        maximum = max(maximum, current)
        return current
    }

    func leave() {
        lock.lock()
        defer { lock.unlock() }
        current -= 1
    }

    var maximumConcurrent: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }
}
