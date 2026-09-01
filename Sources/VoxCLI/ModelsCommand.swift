import ArgumentParser
import Foundation
import VoxKit

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "List, download, select, and remove whisper models.",
        subcommands: [List.self, Download.self, SetModel.self, Remove.self, Path.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List known models and which are installed.")

        @OptionGroup var configOptions: ConfigOptions

        func run() throws {
            let paths = configOptions.paths
            let manager = ModelManager(paths: paths)
            let selected = (try? configOptions.loadConfig())?.model
            for model in ModelCatalog.all {
                let marker = model.id == selected ? "*" : " "
                let state = manager.isInstalled(model) ? "installed" : "not installed"
                let name = model.id.padding(toLength: 22, withPad: " ", startingAt: 0)
                Stdout.write(
                    "\(marker) \(name) \(formatSize(megabytes: model.approximateSizeMB).padding(toLength: 9, withPad: " ", startingAt: 0)) \(state)  \(model.summary)"
                )
            }
        }
    }

    struct Download: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download a model into the Vox support directory."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Model id. Defaults to the configured model.")
        var model: String?

        func run() async throws {
            do {
                let paths = configOptions.paths
                let id = try model ?? configOptions.loadConfig().model
                guard let whisperModel = ModelCatalog.model(id: id) else {
                    throw VoxError.model(
                        "Unknown model '\(id)'",
                        detail: "Known models: \(ModelCatalog.all.map(\.id).joined(separator: ", "))"
                    )
                }
                let manager = ModelManager(paths: paths)
                if manager.isInstalled(whisperModel) {
                    Stderr.write("\(whisperModel.id) is already installed.")
                    Stdout.write(paths.modelFile(for: whisperModel).path)
                    return
                }
                Stderr.write(
                    "Downloading \(whisperModel.id) (~\(formatSize(megabytes: whisperModel.approximateSizeMB)))…"
                )
                let reporter = ProgressReporter()
                let url = try await manager.ensureAvailable(whisperModel) { fraction in
                    reporter.report(fraction)
                }
                reporter.finish()
                Stdout.write(url.path)
            } catch {
                voxError(from: error).printToStderr()
                throw voxExitCode(for: error)
            }
        }
    }

    struct SetModel: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Select the model used by the CLI and the app."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Model id.")
        var model: String

        func run() throws {
            do {
                let updated = try configOptions.store.update { config in
                    try ConfigKeys.set("model", to: model, in: &config)
                }
                Stdout.write(updated.model)
            } catch {
                voxError(from: error).printToStderr()
                throw voxExitCode(for: error)
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a downloaded model file.")

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Model id.")
        var model: String

        func run() throws {
            do {
                guard let whisperModel = ModelCatalog.model(id: model) else {
                    throw VoxError.model("Unknown model '\(model)'")
                }
                try ModelManager(paths: configOptions.paths).remove(whisperModel)
                Stderr.write("Removed \(whisperModel.id).")
            } catch {
                voxError(from: error).printToStderr()
                throw voxExitCode(for: error)
            }
        }
    }

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the models directory.")

        @OptionGroup var configOptions: ConfigOptions

        func run() {
            Stdout.write(configOptions.paths.modelsDirectory.path)
        }
    }
}

/// Rewrites one stderr line rather than scrolling, and only when stderr is a
/// terminal, so piped output stays clean.
final class ProgressReporter {
    private let isTerminal = isatty(FileHandle.standardError.fileDescriptor) == 1
    private var lastPercent = -1

    func report(_ fraction: Double) {
        guard isTerminal else { return }
        let percent = Int((fraction * 100).rounded())
        guard percent != lastPercent else { return }
        lastPercent = percent
        FileHandle.standardError.write(Data("\r\(percent)%".utf8))
    }

    func finish() {
        guard isTerminal else { return }
        FileHandle.standardError.write(Data("\r100%\n".utf8))
    }
}
