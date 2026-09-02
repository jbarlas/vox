import ArgumentParser
import Foundation
import VoxKit

struct Modes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "modes",
        abstract: "List and edit transcript post-processing modes.",
        subcommands: [List.self, Show.self, Add.self, Remove.self, SetDefault.self, Test.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List defined modes.")

        @OptionGroup var configOptions: ConfigOptions

        func run() throws {
            do {
                let config = try configOptions.loadConfig()
                for mode in config.modes {
                    let marker = mode.name == config.defaultMode ? "*" : " "
                    let name = mode.name.padding(toLength: 14, withPad: " ", startingAt: 0)
                    let kind = mode.kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
                    Stdout.write("\(marker) \(name) \(kind) \(mode.description ?? "")")
                }
            } catch {
                voxError(from: error).printToStderr()
                throw voxExitCode(for: error)
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print one mode as JSON.")

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Mode name.")
        var name: String

        func run() throws {
            do {
                guard let mode = try configOptions.loadConfig().mode(named: name) else {
                    throw VoxError.config("Unknown mode '\(name)'")
                }
                Stdout.write(try VoxJSON.string(mode, pretty: true))
            } catch {
                voxError(from: error).printToStderr()
                throw voxExitCode(for: error)
            }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Define or replace an LLM mode.",
            discussion: """
                The prompt becomes the system prompt sent to the configured \
                OpenAI-compatible endpoint (LiteLLM by default). Point a mode at a \
                different model with --model, or at a different endpoint entirely \
                with --provider (or --base-url plus --api-key-env) — so one mode can \
                run on a hosted provider while the rest stay on the local endpoint.
                """
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Mode name.")
        var name: String

        @Option(help: "System prompt. Use - to read from stdin.")
        var prompt: String

        @Option(help: "Model name passed to the LLM endpoint, overriding llm.model.")
        var model: String?

        @Option(
            name: .customLong("provider"),
            help: ArgumentHelp(
                "Run this mode on a known provider instead of llm.base_url "
                    + "(\(LLMProviderCatalog.all.map(\.id).joined(separator: ", ")))."
            )
        )
        var provider: String?

        @Option(help: "OpenAI-compatible endpoint for this mode only, overriding llm.base_url.")
        var baseURL: String?

        @Option(
            name: .customLong("api-key-env"),
            help: ArgumentHelp(
                "Environment variable holding this mode's API key. Required for a "
                    + "remote --base-url: the global llm.api_key_env_var is not forwarded to it."
            )
        )
        var apiKeyEnv: String?

        @Option(help: "Sampling temperature for this mode.")
        var temperature: Double?

        @Option(help: "Human-readable description shown by `vox modes list`.")
        var description: String?

        func run() throws {
            do {
                let promptText: String
                if prompt == "-" {
                    let data = FileHandle.standardInput.readDataToEndOfFile()
                    promptText = String(data: data, encoding: .utf8) ?? ""
                } else {
                    promptText = prompt
                }
                var endpoint: String? = baseURL
                var keyEnvVar: String? = apiKeyEnv
                if let provider {
                    guard let preset = LLMProviderCatalog.provider(id: provider) else {
                        throw VoxError.config(
                            "Unknown provider '\(provider)'",
                            detail: "Known providers: "
                                + LLMProviderCatalog.all.map(\.id).joined(separator: ", ")
                                + ". Use --base-url and --api-key-env for anything else."
                        )
                    }
                    endpoint = baseURL ?? preset.baseURL
                    keyEnvVar = apiKeyEnv ?? preset.apiKeyEnvVar
                }
                let mode = ModeDefinition(
                    name: name,
                    kind: .llm,
                    description: description,
                    prompt: promptText,
                    model: model,
                    baseURL: endpoint,
                    apiKeyEnvVar: keyEnvVar,
                    temperature: temperature
                )
                _ = try configOptions.store.update { config in
                    try config.setMode(mode)
                }
                Stderr.write("Defined mode '\(name)'.")
            } catch {
                voxError(from: error).printToStderr()
                throw voxExitCode(for: error)
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a mode.")

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Mode name.")
        var name: String

        func run() throws {
            do {
                _ = try configOptions.store.update { config in
                    try config.removeMode(named: name)
                }
                Stderr.write("Removed mode '\(name)'.")
            } catch {
                voxError(from: error).printToStderr()
                throw voxExitCode(for: error)
            }
        }
    }

    struct SetDefault: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-default",
            abstract: "Choose the mode used when none is passed."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Mode name.")
        var name: String

        func run() throws {
            do {
                let updated = try configOptions.store.update { config in
                    try ConfigKeys.set("default_mode", to: name, in: &config)
                }
                Stdout.write(updated.defaultMode)
            } catch {
                voxError(from: error).printToStderr()
                throw voxExitCode(for: error)
            }
        }
    }

    struct Test: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a mode against text instead of the microphone.",
            discussion: "The fastest way to check an LLM mode's prompt and LiteLLM routing."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Mode name.")
        var name: String

        @Argument(help: "Text to process. Use - to read from stdin.")
        var text: String

        func run() async throws {
            do {
                let config = try configOptions.loadConfig()
                guard let mode = config.mode(named: name) else {
                    throw VoxError.config("Unknown mode '\(name)'")
                }
                let input: String
                if text == "-" {
                    input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
                } else {
                    input = text
                }
                // Same glossary the pipeline sends, so the test reflects a real dictation.
                let vocabulary = VocabularyEntry.merge(
                    user: config.vocabulary,
                    corpus: CorpusVocabularyStore(paths: configOptions.paths).loadForInference()
                )
                let result = try await ModeRunner(llmConfig: config.llm).run(
                    transcript: input,
                    mode: mode,
                    vocabulary: vocabulary.map(\.term)
                )
                Stdout.write(result.text)
            } catch {
                voxError(from: error).printToStderr()
                throw voxExitCode(for: error)
            }
        }
    }
}
