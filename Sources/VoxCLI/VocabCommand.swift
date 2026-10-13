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
            initial prompt, and a seeded term that collides with one is dropped. \
            To manage seeded folders one at a time instead of re-listing them all \
            on every `seed`, use `vox vocab sources add/remove`.
            """,
        subcommands: [List.self, Add.self, Remove.self, Seed.self, Refresh.self, Sources.self, Notion.self, Clear.self],
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
                    let sources = corpus.sources.map(\.path).joined(separator: ", ")
                    Stderr.write(
                        "\(corpus.activeTerms.count) corpus terms\(excluded) from \(sources) "
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
                var recordedExclusion = false
                _ = try CorpusVocabularyStore(paths: configOptions.paths).update { corpus in
                    guard var updated = corpus else { return }
                    for term in terms {
                        if updated.exclude(term) { excludedCorpus += 1 }
                        recordedExclusion = true
                    }
                    corpus = updated
                }
                if removedUser == 0 && excludedCorpus == 0 && !recordedExclusion {
                    Stderr.write("No matching terms. Nothing has been seeded yet, so nothing was excluded.")
                } else if removedUser == 0 && excludedCorpus == 0 {
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
                let store = CorpusVocabularyStore(paths: configOptions.paths)
                Stderr.write("Scanning…")
                let started = Date()
                let vocabulary = try store.replaceSources(paths, options: extraction.resolved(over: .default))
                report(vocabulary, since: started, store: store)
            } catch {
                voxError(from: error).printToStderr()
                throw voxExitCode(for: error)
            }
        }
    }

    struct Refresh: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Re-run seeding against the previously seeded paths, fetching Notion first if connected."
        )

        @OptionGroup var configOptions: ConfigOptions
        @OptionGroup var extraction: ExtractionOptions

        func run() async throws {
            do {
                let store = CorpusVocabularyStore(paths: configOptions.paths)
                guard let previous = try store.load() else {
                    throw VoxError.config(
                        "Nothing has been seeded yet",
                        detail: "Run `vox vocab seed <path>` first."
                    )
                }
                if previous.sources.contains(where: \.isNotion) { Stderr.write("Fetching Notion…") }
                let started = Date()
                let result = try await NotionVocabulary.refresh(
                    store: store,
                    options: extraction.resolved(over: previous.options),
                    onProgress: notionProgress
                )
                if let notion = result.notion { reportNotion(notion) }
                if let notionError = result.notionError {
                    notionError.printToStderr()
                    Stderr.write("Local folders were still synced, using the Notion pages cached before.")
                }
                guard let vocabulary = result.vocabulary else {
                    throw VoxError.config("Seeded vocabulary was removed while refreshing")
                }
                report(vocabulary, since: started, store: store)
            } catch {
                voxError(from: error).printToStderr()
                throw voxExitCode(for: error)
            }
        }
    }

    struct Sources: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage the folders `vox vocab seed` tracks, without re-specifying all of them each time.",
            subcommands: [List.self, Add.self, Remove.self],
            defaultSubcommand: List.self
        )

        struct List: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show the tracked source folders.")

            @OptionGroup var configOptions: ConfigOptions

            func run() throws {
                do {
                    guard let corpus = try CorpusVocabularyStore(paths: configOptions.paths).load(),
                        !corpus.sources.isEmpty
                    else {
                        Stderr.write("No sources tracked yet. Add one with `vox vocab sources add <path>`.")
                        return
                    }
                    Stdout.write("ADDED                 PATH")
                    for source in corpus.sources {
                        let label =
                            source.isNotion
                            ? "Notion workspace (token in $\(source.tokenEnvVar ?? NotionVocabulary.defaultTokenEnvVar))"
                            : source.path
                        Stdout.write("\(ISO8601.string(from: source.addedAt))  \(label)")
                    }
                } catch {
                    voxError(from: error).printToStderr()
                    throw voxExitCode(for: error)
                }
            }
        }

        struct Add: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Track one or more additional folders and re-sync the whole corpus."
            )

            @OptionGroup var configOptions: ConfigOptions

            @Argument(help: "Folders or files to add.")
            var paths: [String]

            func run() throws {
                do {
                    let store = CorpusVocabularyStore(paths: configOptions.paths)
                    Stderr.write("Scanning…")
                    let started = Date()
                    let vocabulary = try store.addSources(paths)
                    report(vocabulary, since: started, store: store)
                } catch {
                    voxError(from: error).printToStderr()
                    throw voxExitCode(for: error)
                }
            }
        }

        struct Remove: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Stop tracking a folder and re-sync the rest."
            )

            @OptionGroup var configOptions: ConfigOptions

            @Argument(help: "Folders to stop tracking.")
            var paths: [String]

            func run() throws {
                do {
                    let store = CorpusVocabularyStore(paths: configOptions.paths)
                    let started = Date()
                    guard let vocabulary = try store.removeSources(paths) else {
                        Stderr.write("No sources left; seeded vocabulary cleared.")
                        return
                    }
                    report(vocabulary, since: started, store: store)
                } catch {
                    voxError(from: error).printToStderr()
                    throw voxExitCode(for: error)
                }
            }
        }
    }

    struct Notion: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Seed the vocabulary from a Notion workspace.",
            discussion: """
                Create an internal integration at notion.so/profile/integrations, share \
                the pages or teamspaces you want with it, and put its secret in an \
                environment variable (NOTION_TOKEN by default). Vox never stores the \
                token. Pages are cached as Markdown under the vocab folder (owner-only \
                access) and fetched again on `refresh`; only changed pages are re-read.
                """,
            subcommands: [Connect.self, Sync.self, Disconnect.self]
        )

        struct Connect: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Fetch every page shared with the integration and track the workspace as a source."
            )

            @OptionGroup var configOptions: ConfigOptions

            @Option(help: "Environment variable holding the integration secret.")
            var tokenEnvVar = NotionVocabulary.defaultTokenEnvVar

            func run() async throws {
                do {
                    let store = CorpusVocabularyStore(paths: configOptions.paths)
                    Stderr.write("Fetching Notion…")
                    let started = Date()
                    let (vocabulary, notion) = try await NotionVocabulary.connect(
                        store: store,
                        tokenEnvVar: tokenEnvVar,
                        onProgress: notionProgress
                    )
                    reportNotion(notion)
                    report(vocabulary, since: started, store: store)
                } catch {
                    voxError(from: error).printToStderr()
                    throw voxExitCode(for: error)
                }
            }
        }

        struct Sync: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Fetch changed Notion pages and re-sync every source (same as `vox vocab refresh`)."
            )

            @OptionGroup var configOptions: ConfigOptions

            func run() async throws {
                do {
                    let store = CorpusVocabularyStore(paths: configOptions.paths)
                    guard try store.load()?.sources.contains(where: \.isNotion) == true else {
                        throw VoxError.config("Notion is not connected", detail: "Run `vox vocab notion connect` first.")
                    }
                    Stderr.write("Fetching Notion…")
                    let started = Date()
                    let result = try await NotionVocabulary.refresh(store: store, onProgress: notionProgress)
                    if let notionError = result.notionError { throw notionError }
                    if let notion = result.notion { reportNotion(notion) }
                    if let vocabulary = result.vocabulary { report(vocabulary, since: started, store: store) }
                } catch {
                    voxError(from: error).printToStderr()
                    throw voxExitCode(for: error)
                }
            }
        }

        struct Disconnect: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Stop tracking Notion, delete its cached pages, and re-sync the rest."
            )

            @OptionGroup var configOptions: ConfigOptions

            func run() throws {
                do {
                    let store = CorpusVocabularyStore(paths: configOptions.paths)
                    let started = Date()
                    guard let vocabulary = try store.untrackNotion() else {
                        Stderr.write("Notion disconnected; no other sources, so the seeded vocabulary was cleared.")
                        return
                    }
                    Stderr.write("Notion disconnected and its cached pages deleted.")
                    report(vocabulary, since: started, store: store)
                } catch {
                    voxError(from: error).printToStderr()
                    throw voxExitCode(for: error)
                }
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
            help: ArgumentHelp(
                "Ignore terms less than 2^N times as common here as in general English "
                    + "(default \(CorpusExtractionOptions.default.minScore))."
            )
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

/// Overwrites one status line on a terminal; silent when stderr is piped.
private func notionProgress(_ report: NotionSyncReport) {
    guard isatty(STDERR_FILENO) != 0 else { return }
    FileHandle.standardError.write(Data("\r\(report.pagesTotal) Notion pages…".utf8))
}

private func reportNotion(_ report: NotionSyncReport) {
    if isatty(STDERR_FILENO) != 0 { FileHandle.standardError.write(Data("\r".utf8)) }
    var parts = ["\(report.pagesFetched) fetched", "\(report.pagesUnchanged) unchanged"]
    if report.pagesRemoved > 0 { parts.append("\(report.pagesRemoved) removed") }
    if report.pagesSkipped > 0 { parts.append("\(report.pagesSkipped) no longer visible") }
    Stderr.write("Notion: \(report.pagesTotal) pages (\(parts.joined(separator: ", "))).")
}

private func report(_ vocabulary: CorpusVocabulary, since started: Date, store: CorpusVocabularyStore) {
    let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
    Stderr.write(
        "Seeded \(vocabulary.activeTerms.count) terms from \(vocabulary.filesScanned) files "
            + "(\(vocabulary.tokensScanned) tokens) in \(elapsed)s → \(store.paths.corpusVocabularyFile.path)"
    )
    if !vocabulary.missingSources.isEmpty {
        Stderr.write(
            "Skipped missing source(s): \(vocabulary.missingSources.joined(separator: ", ")). "
                + "Stop tracking with `vox vocab sources remove <path>`."
        )
    }
    for term in vocabulary.activeTerms.prefix(20) {
        Stdout.write(term.term)
    }
    if vocabulary.activeTerms.count > 20 {
        Stdout.write("… (\(vocabulary.activeTerms.count - 20) more; see `vox vocab list`)")
    }
}
