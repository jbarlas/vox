import ArgumentParser
import Foundation
import VoxKit

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Inspect and edit the config shared by the CLI and the menu bar app.",
        subcommands: [Initialize.self, Get.self, Set.self, List.self, Path.self, Vocab.self]
    )

    struct Initialize: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "init",
            abstract: "Write a starter config. Idempotent unless --force is given."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Option(help: "Model to record in the new config.")
        var model: String?

        @Flag(help: "Overwrite an existing config.")
        var force = false

        func run() throws {
            do {
                let store = configOptions.store
                let created = try store.initializeIfNeeded(force: force, model: model)
                Stderr.write(
                    created
                        ? "Wrote \(store.paths.configFile.path)"
                        : "Config already exists at \(store.paths.configFile.path) (use --force to overwrite)"
                )
            } catch {
                voxError(from: error).printToStderr()
                throw exitCode(for: error)
            }
        }
    }

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print one config value.")

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Config key, e.g. model or llm.base_url.")
        var key: String

        func run() throws {
            do {
                Stdout.write(try ConfigKeys.get(key, from: try configOptions.loadConfig()))
            } catch {
                voxError(from: error).printToStderr()
                throw exitCode(for: error)
            }
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change one config value.")

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Config key, e.g. model or llm.base_url.")
        var key: String

        @Argument(help: "New value. Use auto/off/none to clear an optional field.")
        var value: String

        func run() throws {
            do {
                let store = configOptions.store
                let updated = try store.update { config in
                    try ConfigKeys.set(key, to: value, in: &config)
                }
                Stdout.write(try ConfigKeys.get(key, from: updated))
            } catch {
                voxError(from: error).printToStderr()
                throw exitCode(for: error)
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print every config key and value.")

        @OptionGroup var configOptions: ConfigOptions

        @Flag(help: "Print the raw config JSON instead of a key/value table.")
        var json = false

        func run() throws {
            do {
                let config = try configOptions.loadConfig()
                if json {
                    Stdout.write(try VoxJSON.string(config, pretty: true))
                    return
                }
                let width = ConfigKeys.all.map(\.count).max() ?? 0
                for key in ConfigKeys.all {
                    let value = try ConfigKeys.get(key, from: config)
                    Stdout.write(key.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + value)
                }
            } catch {
                voxError(from: error).printToStderr()
                throw exitCode(for: error)
            }
        }
    }

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the config file path.")

        @OptionGroup var configOptions: ConfigOptions

        func run() {
            Stdout.write(configOptions.paths.configFile.path)
        }
    }

    struct Vocab: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage the custom vocabulary injected as whisper.cpp's initial prompt."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Option(help: "Add these comma-separated terms.")
        var add: String?

        @Option(help: "Remove these comma-separated terms.")
        var remove: String?

        @Flag(help: "Remove every term.")
        var clear = false

        @Flag(help: "Print the initial prompt that will be sent to whisper.cpp.")
        var showPrompt = false

        func run() throws {
            do {
                let store = configOptions.store
                var config = try store.load()
                var mutated = false

                if clear {
                    config.vocabulary = []
                    mutated = true
                }
                if let add {
                    config.vocabulary = VocabInjector.normalize(config.vocabulary + Self.terms(add))
                    mutated = true
                }
                if let remove {
                    // Fully qualified: `Set` resolves to the sibling subcommand
                    // struct inside this scope.
                    let dropped = Swift.Set(Self.terms(remove).map { $0.lowercased() })
                    config.vocabulary = config.vocabulary.filter { !dropped.contains($0.lowercased()) }
                    mutated = true
                }
                if mutated {
                    try store.save(config)
                }
                if showPrompt {
                    Stdout.write(VocabInjector.initialPrompt(vocabulary: config.vocabulary) ?? "(no prompt)")
                } else {
                    for term in config.vocabulary { Stdout.write(term) }
                }
            } catch {
                voxError(from: error).printToStderr()
                throw exitCode(for: error)
            }
        }

        private static func terms(_ raw: String) -> [String] {
            raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }
}
