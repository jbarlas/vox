import Foundation

/// Reads and writes the shared config document.
///
/// Writes are atomic so a menu bar app save can never leave a half-written file
/// for a concurrently running `vox record`.
public final class ConfigStore {
    public let paths: VoxPaths
    private let fileManager: FileManager

    public init(paths: VoxPaths = VoxPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public var configExists: Bool {
        fileManager.fileExists(atPath: paths.configFile.path)
    }

    /// Loads the config, falling back to defaults when no file exists yet, so
    /// the CLI works before `vox config init` has ever run.
    public func load() throws -> VoxConfig {
        guard configExists else { return VoxConfig() }
        let data: Data
        do {
            data = try Data(contentsOf: paths.configFile)
        } catch {
            throw VoxError.config(
                "Could not read config at \(paths.configFile.path)",
                detail: error.localizedDescription
            )
        }
        let config: VoxConfig
        do {
            config = try VoxJSON.decoder().decode(VoxConfig.self, from: data)
        } catch {
            throw VoxError.config(
                "Config at \(paths.configFile.path) is not valid Vox JSON",
                detail: String(describing: error)
            )
        }
        try config.validate()
        return config
    }

    public func save(_ config: VoxConfig) throws {
        try config.validate()
        try paths.createSupportDirectories()
        let data = try VoxJSON.encoder(pretty: true).encode(config)
        do {
            // Atomic so a crash mid-write cannot leave the app and the CLI
            // sharing a truncated config.
            try data.write(to: paths.configFile, options: .atomic)
        } catch {
            throw VoxError.config(
                "Could not write config to \(paths.configFile.path)",
                detail: error.localizedDescription
            )
        }
    }

    private static let backupTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Moves an unreadable config aside, returning where it went. Callers do
    /// this before writing over a file they could not parse, so hand-edited
    /// settings survive a syntax error.
    @discardableResult
    public func quarantineUnreadableFile() throws -> URL? {
        guard configExists else { return nil }
        // Timestamped: a second bad config must not erase the first recovery
        // copy, which may be the one the user actually wants back.
        let directory = paths.configFile.deletingLastPathComponent()
        let stamp = Self.backupTimestamp.string(from: Date())
        var backup = directory.appendingPathComponent("config.invalid-\(stamp).json")
        var suffix = 2
        while fileManager.fileExists(atPath: backup.path) {
            backup = directory.appendingPathComponent("config.invalid-\(stamp)-\(suffix).json")
            suffix += 1
        }
        do {
            try fileManager.moveItem(at: paths.configFile, to: backup)
        } catch {
            throw VoxError.config(
                "Could not move the unreadable config aside",
                detail: error.localizedDescription
            )
        }
        return backup
    }

    /// Creates a starter config. Returns `false` when one already existed and
    /// `force` was not requested, which keeps `make setup` idempotent.
    @discardableResult
    public func initializeIfNeeded(force: Bool = false, model: String? = nil) throws -> Bool {
        if configExists && !force { return false }
        var config = VoxConfig()
        if let model {
            guard ModelCatalog.model(id: model) != nil else {
                throw VoxError.config(
                    "Unknown model '\(model)'",
                    detail: "Known models: \(ModelCatalog.all.map(\.id).joined(separator: ", "))"
                )
            }
            config.model = model
        }
        try save(config)
        return true
    }

    public func update(_ mutate: (inout VoxConfig) throws -> Void) throws -> VoxConfig {
        var config = try load()
        try mutate(&config)
        try save(config)
        return config
    }
}
