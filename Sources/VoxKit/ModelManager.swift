import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Downloads and inspects the GGML models kept in the Vox support directory.
public final class ModelManager: NSObject {
    public struct InstalledModel: Sendable, Equatable {
        public let model: WhisperModel
        public let url: URL
        public let sizeBytes: Int64
    }

    private let paths: VoxPaths
    private let fileManager: FileManager
    /// Boxed so the delegate callbacks can read it from an arbitrary thread
    /// without making `ModelManager` itself mutable-and-Sendable.
    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: ((Double) -> Void)?

        func set(_ handler: ((Double) -> Void)?) {
            lock.lock()
            defer { lock.unlock() }
            self.handler = handler
        }

        func report(_ fraction: Double) {
            lock.lock()
            let handler = self.handler
            lock.unlock()
            handler?(fraction)
        }
    }

    private let progress = ProgressBox()

    public init(paths: VoxPaths = VoxPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        super.init()
    }

    public func isInstalled(_ model: WhisperModel) -> Bool {
        fileManager.fileExists(atPath: paths.modelFile(for: model).path)
    }

    public func installed() -> [InstalledModel] {
        ModelCatalog.all.compactMap { model in
            let url = paths.modelFile(for: model)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                let size = attributes[.size] as? Int64
            else { return nil }
            return InstalledModel(model: model, url: url, sizeBytes: size)
        }
    }

    /// Returns the local path of a ready-to-use model, downloading it first if
    /// needed. Never partially overwrites an existing file: the download lands
    /// on a temporary path and is moved into place only once complete.
    public func ensureAvailable(
        _ model: WhisperModel,
        progress: ((Double) -> Void)? = nil
    ) async throws -> URL {
        let destination = paths.modelFile(for: model)
        if fileManager.fileExists(atPath: destination.path) { return destination }
        try paths.createSupportDirectories()

        let source = ModelCatalog.downloadURL(for: model)
        self.progress.set(progress)
        defer { self.progress.set(nil) }

        let temporaryURL: URL
        do {
            temporaryURL = try await download(from: source)
        } catch {
            throw VoxError.model(
                "Could not download model '\(model.id)'",
                detail: "\(source.absoluteString): \(error.localizedDescription)"
            )
        }
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destination)
            }
        } catch {
            // Otherwise a repeatedly failing install strands a model-sized file
            // per attempt.
            try? fileManager.removeItem(at: temporaryURL)
            throw VoxError.model(
                "Could not install model '\(model.id)' into \(destination.path)",
                detail: error.localizedDescription
            )
        }
        return destination
    }

    public func remove(_ model: WhisperModel) throws {
        let url = paths.modelFile(for: model)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw VoxError.model("Could not remove model '\(model.id)'", detail: error.localizedDescription)
        }
    }

    /// Uses a download task rather than `data(for:)` so multi-gigabyte models
    /// stream to disk instead of into memory.
    private func download(from source: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: source) { location, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let httpResponse = response as? HTTPURLResponse,
                    !(200..<300).contains(httpResponse.statusCode)
                {
                    continuation.resume(
                        throwing: VoxError.model("Model download failed with HTTP \(httpResponse.statusCode)")
                    )
                    return
                }
                guard let location else {
                    continuation.resume(throwing: VoxError.model("Model download produced no file"))
                    return
                }
                // The delegate-provided file is deleted when this callback
                // returns, so move it somewhere we control first.
                let staged = FileManager.default.temporaryDirectory
                    .appendingPathComponent("vox-model-\(UUID().uuidString)")
                do {
                    try FileManager.default.moveItem(at: location, to: staged)
                    continuation.resume(returning: staged)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            task.resume()
        }
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress.report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Handled in the completion handler above.
    }
}
