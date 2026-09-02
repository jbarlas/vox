import ArgumentParser
import Foundation
import VoxKit

/// `vox vocab`: the effective vocabulary Whisper and LLM modes are biased
/// toward — hand-added terms (stored in config.json, also reachable via
/// `vox config vocab`) plus terms seeded from a corpus of the user's own notes
/// (stored in vocab/corpus.json).
struct VocabCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vocab",
        abstract: "Manage the vocabulary Whisper is biased toward, by hand or seeded from your notes.",
        discussion: """
            User-added terms always outrank seeded ones: they lead the whisper.cpp \
            initial prompt, and a seeded term that collides with one is dropped.
            """,
        subcommands: [List.self, Add.self, Remove.self, Seed.self, Refresh.self, Clear.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the merged effective vocabulary with each term's source and weight."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Flag(help: "Print as JSON.")
        var json = false

        @Flag(help: "Print the initial prompt that will be sent to whisper.cpp instead.")
        var showPrompt = false

        func run() throws {
            do {
                let config = try configOptions.loadConfig()
                let corpus = try CorpusVocabularyStore(paths: configOptions.paths).load()
                let entries = VocabularyEntry.merge(user: config.vocabulary, corpus: corpus)
                if showPrompt {
                    Stdout.write(VocabInjector.initialPrompt(entries: entries) ?? "(no prompt)")
                    return
                }
                if json {
                    Stdout.write(try VoxJSON.string(entries.map(ListedEntry.init), pretty: true))
                    return
                }
                if entries.isEmpty {
                    Stderr.write("No vocabulary. Add terms with `vox vocab add` or seed them with `vox vocab seed <path>`.")
                    return
                }
                Stdout.write("SOURCE  WEIGHT  SCORE  TERM")
                for entry in entries {
                    let source = entry.source.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)
                    let weight = String(format: "%.2f", entry.weight).padding(toLength: 6, withPad: " ", startingAt: 0)
                    let score = entry.score.map { String(format: "%5.1f", $0) } ?? "    -"
                    Stdout.write("\(source)  \(weight)  \(score)  \(entry.term)")
                }
                if let corpus {
                    let excluded = corpus.excluded.isEmpty ? "" : ", \(corpus.excluded.count) excluded"
                    Stderr.write(
                        "\(corpus.activeTerms.count) corpus terms\(excluded) from \(corpus.sources.joined(separator: ", ")) "
                            + "(seeded \(ISO8601.string(from: corpus.generatedAt)))"
                    )
                }
            } catch {
                voxError(from: error).printToStderr()
                throw voxExitCode(for: error)
            }
        }

        private struct ListedEntry: Encodable {
            let term: String
            let source: String
            let weight: Double
            let score: Double?

            init(_ entry: VocabularyEntry) {
                term = entry.term
                source = entry.source.rawValue
                weight = entry.weight
                score = entry.score
            }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add user vocabulary terms (the same list as `vox config vocab --add`)."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Terms to add.")
        var terms: [String]

        func run() throws {
            do {
                let updated = try configOptions.store.update { config in
                    config.vocabulary = VocabInjector.normalize(config.vocabulary + terms)
                }
                Stderr.write("\(updated.vocabulary.count) user terms.")
            } catch {
                voxError(from: error).printToStderr()
                throw voxExitCode(for: error)
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Drop terms from the effective vocabulary.",
            discussion: """
                A user-added term is deleted from config.json. A seeded term is \
                excluded from corpus.json and stays excluded across `vox vocab refresh`.
                """
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Terms to remove (case-insensitive).")
        var terms: [String]

        func run() throws {
            do {
                let keys = Set(terms.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                var removedUser = 0
                _ = try configOptions.store.update { config in
                    let before = config.vocabulary.count
                    config.vocabulary.removeAll { keys.contains($0.lowercased()) }
                    removedUser = before - config.vocabulary.count
                }
                var excludedCorpus = 0
                _ = try CorpusVocabularyStore(paths: configOptions.paths).update { corpus in
                    guard var updated = corpus else { return }
                    for term in terms where updated.exclude(term) {
                        excludedCorpus += 1
                    }
                    corpus = updated
                }
                if removedUser == 0 && excludedCorpus == 0 {
                    Stderr.write("No matching terms; recorded as excluded for future seeding.")
                } else {
                    Stderr.write("Removed \(removedUser) user term(s), excluded \(excludedCorpus) seeded term(s).")
                }
            } catch {
                voxError(from: error).printToStderr()
                throw voxExitCode(for: error)
            }
        }
    }

    struct Seed: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Scan folders/files of notes and seed the vocabulary with their distinctive terms.",
            discussion: """
                Recursively reads every .md and .txt file under the given paths and \
                keeps the terms used far more often there than in general English \
                (project names, jargon, people). Fully offline. Replaces any previous \
                seeding; terms removed with `vox vocab remove` stay excluded. Expect a \
                few seconds for a large notes vault.
                """
        )

        @OptionGroup var configOptions: ConfigOptions
        @OptionGroup var extraction: ExtractionOptions

        @Argument(help: "Folders or files to scan.")
        var paths: [String]

        func run() throws {
            do {
                let sources = paths.map { (($0 as NSString).expandingTildeInPath as NSString).standardizingPath }
                let previous = try CorpusVocabularyStore(paths: configOptions.paths).load()
                try seedCorpus(
                    sources: sources,
                    options: extraction.resolved(over: .default),
                    excluded: previous?.excluded ?? [],
                    configOptions: configOptions
                )
            } catch {
                voxError(from: error).printToStderr()
                throw voxExitCode(for: error)
            }
        }
    }

    struct Refresh: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Re-run seeding against the previously seeded paths."
        )

        @OptionGroup var configOptions: ConfigOptions
        @OptionGroup var extraction: ExtractionOptions

        func run() throws {
            do {
                guard let previous = try CorpusVocabularyStore(paths: configOptions.paths).load() else {
                    throw VoxError.config(
                        "Nothing has been seeded yet",
                        detail: "Run `vox vocab seed <path>` first."
                    )
                }
                try seedCorpus(
                    sources: previous.sources,
                    options: extraction.resolved(over: previous.options),
                    excluded: previous.excluded,
                    configOptions: configOptions
                )
            } catch {
                voxError(from: error).printToStderr()
                throw voxExitCode(for: error)
            }
        }
    }

    struct Clear: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete the seeded vocabulary (user-added terms are kept)."
        )

        @OptionGroup var configOptions: ConfigOptions

        func run() throws {
            do {
                try CorpusVocabularyStore(paths: configOptions.paths).remove()
                Stderr.write("Seeded vocabulary cleared.")
            } catch {
                voxError(from: error).printToStderr()
                throw voxExitCode(for: error)
            }
        }
    }

    struct ExtractionOptions: ParsableArguments {
        @Option(help: "Keep at most this many terms (default \(CorpusExtractionOptions.default.maxTerms)).")
        var maxTerms: Int?

        @Option(help: "Ignore terms seen fewer times than this (default \(CorpusExtractionOptions.default.minCount)).")
        var minCount: Int?

        @Option(
            help: "Ignore terms less than 2^N times as common here as in general English "
                + "(default \(CorpusExtractionOptions.default.minScore))."
        )
        var minScore: Double?

        func resolved(over base: CorpusExtractionOptions) -> CorpusExtractionOptions {
            var options = base
            if let maxTerms { options.maxTerms = maxTerms }
            if let minCount { options.minCount = minCount }
            if let minScore { options.minScore = minScore }
            return options
        }
    }
}

private func seedCorpus(
    sources: [String],
    options: CorpusExtractionOptions,
    excluded: [String],
    configOptions: ConfigOptions
) throws {
    let started = Date()
    let files = try CorpusVocabularyExtractor.textFiles(under: sources.map { URL(fileURLWithPath: $0) })
    guard !files.isEmpty else {
        throw VoxError.config(
            "No .md or .txt files found under: \(sources.joined(separator: ", "))"
        )
    }
    Stderr.write("Scanning \(files.count) file(s)…")
    let result = try CorpusVocabularyExtractor(options: options).extract(files: files)
    let vocabulary = CorpusVocabulary(
        sources: sources,
        options: options,
        filesScanned: result.filesScanned,
        tokensScanned: result.tokensScanned,
        terms: result.terms,
        excluded: excluded
    )
    let store = CorpusVocabularyStore(paths: configOptions.paths)
    _ = try store.update { $0 = vocabulary }
    let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
    Stderr.write(
        "Seeded \(vocabulary.activeTerms.count) terms from \(result.filesScanned) files "
            + "(\(result.tokensScanned) tokens) in \(elapsed)s → \(store.paths.corpusVocabularyFile.path)"
    )
    for term in vocabulary.activeTerms.prefix(20) {
        Stdout.write(term.term)
    }
    if vocabulary.activeTerms.count > 20 {
        Stdout.write("… (\(vocabulary.activeTerms.count - 20) more; see `vox vocab list`)")
    }
}
