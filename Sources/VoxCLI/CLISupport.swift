import ArgumentParser
import Foundation
import VoxKit

/// Progress and diagnostics go to stderr so `--output json` keeps stdout a
/// single parseable document.
enum Stderr {
    static func write(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

enum Stdout {
    static func write(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }
}

extension VoxError {
    /// Human-readable failure on stderr for interactive use.
    func printToStderr() {
        Stderr.write("vox: \(message)")
        if let detail, !detail.isEmpty {
            Stderr.write("      \(detail)")
        }
    }
}

/// Converts any thrown error into a `VoxError` and then into an `ExitCode`,
/// which is how the CLI keeps its exit-status contract with agent harnesses.
///
/// Named `voxExitCode` (not `exitCode`) to avoid colliding with
/// `ParsableArguments.exitCode(for:)`, which every command struct inherits
/// as a static member of the same name and signature.
func voxExitCode(for error: Error) -> ExitCode {
    ExitCode(voxError(from: error).exitCode)
}

func voxError(from error: Error) -> VoxError {
    if let error = error as? VoxError { return error }
    if error is CancellationError {
        return VoxError(code: .cancelled, message: "Cancelled")
    }
    return VoxError(
        code: .internalError,
        message: error.localizedDescription,
        detail: String(describing: error)
    )
}

struct ConfigOptions: ParsableArguments {
    @Option(
        name: .customLong("config-dir"),
        help: "Support directory holding config.json and models (overrides $VOX_HOME)."
    )
    var configDirectory: String?

    var paths: VoxPaths {
        if let configDirectory {
            return VoxPaths(
                supportDirectory: URL(fileURLWithPath: (configDirectory as NSString).expandingTildeInPath)
            )
        }
        return VoxPaths()
    }

    var store: ConfigStore { ConfigStore(paths: paths) }

    func loadConfig() throws -> VoxConfig {
        try store.load()
    }
}

func formatSize(megabytes: Int) -> String {
    megabytes >= 1024
        ? String(format: "%.1f GB", Double(megabytes) / 1024)
        : "\(megabytes) MB"
}

func formatSize(bytes: Int64) -> String {
    formatSize(megabytes: Int(bytes / 1_048_576))
}
