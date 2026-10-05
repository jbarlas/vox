import Foundation

/// One term surfaced by `vox vocab seed`.
public struct CorpusTerm: Codable, Sendable, Equatable {
    /// The most common surface form in the corpus, casing preserved.
    public var term: String
    /// Distinctiveness: log2 of how much more often the term occurs in the
    /// corpus than in general English. Higher is more domain-specific.
    public var score: Double
    /// Occurrences in the corpus, all casings combined.
    public var count: Int

    public init(term: String, score: Double, count: Int) {
        self.term = term
        self.score = score
        self.count = count
    }
}

/// One folder or file `vox vocab seed`/`sources add` was pointed at, or the
/// connected Notion workspace.
public struct CorpusSource: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case folder
        /// `path` is the local cache `NotionSyncer` mirrors pages into.
        case notion
    }

    public var path: String
    /// When this path was added to tracking. Independent of `generatedAt`,
    /// which is when the corpus was last (re-)scanned as a whole.
    public var addedAt: Date
    /// `nil` in files written before Notion support; read as `.folder`.
    public var kind: Kind?
    /// Notion only: the environment variable holding the integration token.
    /// The token itself is never stored.
    public var tokenEnvVar: String?

    public init(path: String, addedAt: Date = Date(), kind: Kind? = nil, tokenEnvVar: String? = nil) {
        self.path = path
        self.addedAt = addedAt
        self.kind = kind
        self.tokenEnvVar = tokenEnvVar
    }

    public var isNotion: Bool { kind == .notion }
}

/// Knobs for one extraction run, persisted with the result so `vox vocab
/// refresh` reproduces the same list against fresh text.
public struct CorpusExtractionOptions: Codable, Sendable, Equatable {
    /// Cap on the persisted list. Whisper's prompt window is small, so a longer
    /// list mostly gets truncated anyway.
    public var maxTerms: Int
    /// Terms seen fewer times than this are dropped: a single occurrence is as
    /// likely a typo as a domain term.
    public var minCount: Int
    /// Tokens shorter than this are dropped.
    public var minLength: Int
    /// Minimum log2 over-representation versus general English. The default
    /// (2 bits, i.e. at least 4x) keeps function words that happen to be a bit
    /// dense in one corpus — "the", "and" — off the list.
    public var minScore: Double

    public init(maxTerms: Int = 200, minCount: Int = 2, minLength: Int = 3, minScore: Double = 2) {
        self.maxTerms = maxTerms
        self.minCount = minCount
        self.minLength = minLength
        self.minScore = minScore
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxTerms = try container.decode(Int.self, forKey: .maxTerms)
        minCount = try container.decode(Int.self, forKey: .minCount)
        minLength = try container.decode(Int.self, forKey: .minLength)
        minScore = try container.decodeIfPresent(Double.self, forKey: .minScore) ?? 2
    }

    public static let `default` = CorpusExtractionOptions()

    public func validate() throws {
        guard maxTerms > 0 else { throw VoxError.config("max terms must be greater than 0") }
        guard minCount > 0 else { throw VoxError.config("min count must be greater than 0") }
        guard minLength > 0 else { throw VoxError.config("min length must be greater than 0") }
        guard minScore >= 0 else { throw VoxError.config("min score must not be negative") }
    }
}

/// The on-disk artifact behind `vox vocab`: what was scanned, with which
/// options, and what came out. Lives at `VoxPaths.corpusVocabularyFile`.
public struct CorpusVocabulary: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    /// Weight for every corpus term. Below `VocabularyEntry.userWeight` by
    /// design: a seeded term is a statistical guess, a user-added one is not.
    public static let weight = 0.5

    public var schemaVersion: Int
    /// When the corpus was last (re-)scanned as a whole. Scoring is a
    /// whole-corpus statistic, so adding or removing one source re-scans
    /// everything and moves this for all of them together.
    public var generatedAt: Date
    /// Folders/files tracked, each with its own `addedAt`. Replayed by
    /// `refresh`; edited incrementally by `vox vocab sources add/remove`.
    public var sources: [CorpusSource]
    public var options: CorpusExtractionOptions
    public var filesScanned: Int
    public var tokensScanned: Int
    /// Ranked, most distinctive first.
    public var terms: [CorpusTerm]
    /// Lowercased terms the user removed with `vox vocab remove`; they stay out
    /// across refreshes.
    public var excluded: [String]
    /// Tracked sources that did not exist at the last sync. They stay tracked
    /// (a drive may be unmounted) but are skipped instead of failing it.
    public var missingSources: [String]

    public init(
        schemaVersion: Int = CorpusVocabulary.currentSchemaVersion,
        generatedAt: Date = Date(),
        sources: [CorpusSource],
        options: CorpusExtractionOptions = .default,
        filesScanned: Int = 0,
        tokensScanned: Int = 0,
        terms: [CorpusTerm],
        excluded: [String] = [],
        missingSources: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.sources = sources
        self.options = options
        self.filesScanned = filesScanned
        self.tokensScanned = tokensScanned
        self.terms = terms
        self.excluded = excluded
        self.missingSources = missingSources
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion =
            try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? CorpusVocabulary.currentSchemaVersion
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date()
        if let typed = try? container.decodeIfPresent([CorpusSource].self, forKey: .sources) {
            // Current shape: path + its own addedAt.
            sources = typed
        } else if let legacy = try container.decodeIfPresent([String].self, forKey: .sources) {
            // Pre-per-folder shape: bare paths. Backfill addedAt with the
            // corpus's generation time since we have no better answer.
            let backfilledAddedAt = generatedAt
            sources = legacy.map { CorpusSource(path: $0, addedAt: backfilledAddedAt) }
        } else {
            sources = []
        }
        options = try container.decodeIfPresent(CorpusExtractionOptions.self, forKey: .options) ?? .default
        filesScanned = try container.decodeIfPresent(Int.self, forKey: .filesScanned) ?? 0
        tokensScanned = try container.decodeIfPresent(Int.self, forKey: .tokensScanned) ?? 0
        terms = try container.decodeIfPresent([CorpusTerm].self, forKey: .terms) ?? []
        excluded = try container.decodeIfPresent([String].self, forKey: .excluded) ?? []
        missingSources = try container.decodeIfPresent([String].self, forKey: .missingSources) ?? []
    }

    /// `terms` minus `excluded`, in rank order — what inference actually sees.
    public var activeTerms: [CorpusTerm] {
        let excludedKeys = Set(excluded)
        return terms.filter { !excludedKeys.contains($0.term.lowercased()) }
    }

    /// Records an exclusion. Returns `false` when the term was neither listed
    /// nor already excluded, so the CLI can say so.
    @discardableResult
    public mutating func exclude(_ term: String) -> Bool {
        let key = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return false }
        let known = terms.contains { $0.term.lowercased() == key }
        if !excluded.contains(key) {
            excluded.append(key)
        }
        return known
    }
}

/// One line of `vox vocab list`: where a term came from and how much to trust it.
public struct VocabularyEntry: Sendable, Equatable {
    public enum Source: String, Sendable {
        case user
        case corpus
    }

    public static let userWeight = 1.0

    public var term: String
    public var source: Source
    public var weight: Double
    /// Corpus terms only.
    public var score: Double?

    public init(term: String, source: Source, weight: Double, score: Double? = nil) {
        self.term = term
        self.source = source
        self.weight = weight
        self.score = score
    }

    /// User terms first and always present; corpus terms follow in rank order,
    /// minus any that collide case-insensitively with a user term. The order
    /// matters downstream: `VocabInjector` truncates from the end, so user
    /// terms are the last to be dropped.
    public static func merge(user: [String], corpus: CorpusVocabulary?) -> [VocabularyEntry] {
        var seen = Set<String>()
        var entries: [VocabularyEntry] = []
        for term in VocabInjector.normalize(user) {
            seen.insert(term.lowercased())
            entries.append(VocabularyEntry(term: term, source: .user, weight: userWeight))
        }
        for term in corpus?.activeTerms ?? [] where seen.insert(term.term.lowercased()).inserted {
            entries.append(
                VocabularyEntry(term: term.term, source: .corpus, weight: CorpusVocabulary.weight, score: term.score)
            )
        }
        return entries
    }
}

/// Loads and saves `corpus.json`.
///
/// Reads are a single small JSON decode, cheap enough to do once per
/// `DictationPipeline` — extraction never runs on the inference path.
public final class CorpusVocabularyStore {
    public let paths: VoxPaths
    private let fileManager: FileManager

    public init(paths: VoxPaths = VoxPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public var exists: Bool {
        fileManager.fileExists(atPath: paths.corpusVocabularyFile.path)
    }

    /// Every write path loads first, so re-seeding cannot recover a bad file.
    private static let clearHint = " Run `vox vocab clear` to start over, then seed again."

    /// Absolute, tilde-expanded and standardized, so a relative `vox vocab
    /// seed notes` still resolves from another directory or from the app.
    public static func normalizedPath(
        _ path: String,
        relativeTo base: String = FileManager.default.currentDirectoryPath
    ) -> String {
        var expanded = (path as NSString).expandingTildeInPath
        if !expanded.hasPrefix("/") {
            expanded = (base as NSString).appendingPathComponent(expanded)
        }
        return (expanded as NSString).standardizingPath
    }

    /// Paths the user just typed must exist; tracked ones may go missing.
    private func requireExisting(_ paths: [String]) throws {
        let missing = paths.filter { !fileManager.fileExists(atPath: $0) }
        guard missing.isEmpty else {
            throw VoxError.config("No such file or directory: \(missing.joined(separator: ", "))")
        }
    }

    /// `nil` when nothing has been seeded yet.
    public func load() throws -> CorpusVocabulary? {
        guard exists else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: paths.corpusVocabularyFile)
        } catch {
            throw VoxError.config(
                "Could not read seeded vocabulary at \(paths.corpusVocabularyFile.path)",
                detail: error.localizedDescription + Self.clearHint
            )
        }
        let vocabulary: CorpusVocabulary
        do {
            vocabulary = try VoxJSON.decoder().decode(CorpusVocabulary.self, from: data)
        } catch {
            throw VoxError.config(
                "Seeded vocabulary at \(paths.corpusVocabularyFile.path) is not valid Vox JSON",
                detail: String(describing: error) + Self.clearHint
            )
        }
        guard vocabulary.schemaVersion <= CorpusVocabulary.currentSchemaVersion else {
            throw VoxError.config(
                "Seeded vocabulary schema version \(vocabulary.schemaVersion) is newer than this build supports",
                detail: "Upgrade Vox." + Self.clearHint
            )
        }
        return vocabulary
    }

    /// For the transcription path: a missing or corrupt file must never break a
    /// dictation, so it simply yields no corpus terms.
    public func loadForInference() -> CorpusVocabulary? {
        (try? load()) ?? nil
    }

    public func save(_ vocabulary: CorpusVocabulary) throws {
        do {
            try fileManager.createDirectory(at: paths.vocabularyDirectory, withIntermediateDirectories: true)
            let data = try VoxJSON.encoder(pretty: true).encode(vocabulary)
            try data.write(to: paths.corpusVocabularyFile, options: .atomic)
        } catch {
            throw VoxError.config(
                "Could not write seeded vocabulary to \(paths.corpusVocabularyFile.path)",
                detail: error.localizedDescription
            )
        }
    }

    /// Also deletes the Notion cache, which holds copies of workspace pages.
    public func remove() throws {
        try removeNotionCache()
        guard exists else { return }
        try fileManager.removeItem(at: paths.corpusVocabularyFile)
    }

    private func removeNotionCache() throws {
        if fileManager.fileExists(atPath: paths.notionCacheDirectory.path) {
            try fileManager.removeItem(at: paths.notionCacheDirectory)
        }
    }

    /// Tracks the Notion cache as a source (replacing any earlier Notion
    /// source, so the token variable can change) and re-syncs. Call after
    /// `NotionSyncer` has filled the cache.
    @discardableResult
    public func trackNotion(tokenEnvVar: String) throws -> CorpusVocabulary {
        try FileLock.withLock(at: paths.corpusVocabularyLockFile) {
            let previous = try load()
            let existing = previous?.sources.first(where: \.isNotion)
            var sources = (previous?.sources ?? []).filter { !$0.isNotion }
            sources.append(
                CorpusSource(
                    path: paths.notionCacheDirectory.path,
                    addedAt: existing?.addedAt ?? Date(),
                    kind: .notion,
                    tokenEnvVar: tokenEnvVar
                )
            )
            return try sync(sources: sources, options: previous?.options ?? .default, excluded: previous?.excluded ?? [])
        }
    }

    /// Stops tracking Notion, deletes its cache and re-syncs the rest.
    /// Returns `nil` (and clears corpus.json) when nothing else is tracked.
    @discardableResult
    public func untrackNotion() throws -> CorpusVocabulary? {
        try FileLock.withLock(at: paths.corpusVocabularyLockFile) {
            try removeNotionCache()
            guard let previous = try load() else { return nil }
            let remaining = previous.sources.filter { !$0.isNotion }
            guard !remaining.isEmpty else {
                try fileManager.removeItem(at: paths.corpusVocabularyFile)
                return nil
            }
            return try sync(sources: remaining, options: previous.options, excluded: previous.excluded)
        }
    }

    /// Read-modify-write under the cross-process lock, mirroring `ConfigStore`.
    public func update(
        _ mutate: (inout CorpusVocabulary?) throws -> Void
    ) throws -> CorpusVocabulary? {
        try FileLock.withLock(at: paths.corpusVocabularyLockFile) {
            var vocabulary = try load()
            try mutate(&vocabulary)
            if let vocabulary {
                try save(vocabulary)
            } else {
                try remove()
            }
            return vocabulary
        }
    }

    /// Re-scans every file under `sources` and overwrites the stored corpus
    /// with fresh terms and stats. Scoring is a whole-corpus statistic, so
    /// this is the only place extraction happens: `seed`, `refresh`,
    /// `addSources`, and `removeSources` all funnel through it.
    @discardableResult
    public func sync(
        sources: [CorpusSource],
        options: CorpusExtractionOptions,
        excluded: [String]
    ) throws -> CorpusVocabulary {
        try FileLock.withLock(at: paths.corpusVocabularyLockFile) {
            let present = sources.filter { fileManager.fileExists(atPath: $0.path) }
            let missing = sources.map(\.path).filter { !fileManager.fileExists(atPath: $0) }
            guard !present.isEmpty else {
                throw VoxError.config("None of the tracked sources exist: \(missing.joined(separator: ", "))")
            }
            let files = try CorpusVocabularyExtractor.textFiles(
                under: present.map { URL(fileURLWithPath: $0.path) }
            )
            guard !files.isEmpty else {
                throw VoxError.config(
                    "No .md or .txt files found under: \(present.map(\.path).joined(separator: ", "))"
                )
            }
            let result = try CorpusVocabularyExtractor(options: options).extract(files: files)
            let vocabulary = CorpusVocabulary(
                sources: sources,
                options: options,
                filesScanned: result.filesScanned,
                tokensScanned: result.tokensScanned,
                terms: result.terms,
                excluded: excluded,
                missingSources: missing
            )
            try save(vocabulary)
            return vocabulary
        }
    }

    /// Re-syncs the stored corpus with the sources and exclusions on disk,
    /// read under the lock, so a source added or a term excluded by another
    /// process since the caller last loaded is kept rather than overwritten.
    /// Returns `nil` when nothing has been seeded.
    @discardableResult
    public func resync(options: CorpusExtractionOptions? = nil) throws -> CorpusVocabulary? {
        try FileLock.withLock(at: paths.corpusVocabularyLockFile) {
            guard let previous = try load() else { return nil }
            return try sync(
                sources: previous.sources,
                options: options ?? previous.options,
                excluded: previous.excluded
            )
        }
    }

    /// What `vox vocab seed` does: tracks exactly `newPaths` (plus a connected
    /// Notion workspace), keeping the `addedAt` of any already tracked and the
    /// exclusions on disk, all read under the lock so a concurrent change is
    /// not overwritten.
    @discardableResult
    public func replaceSources(
        _ newPaths: [String],
        options: CorpusExtractionOptions
    ) throws -> CorpusVocabulary {
        try FileLock.withLock(at: paths.corpusVocabularyLockFile) {
            let previous = try load()
            var seen = Set<String>()
            let standardized = newPaths.map { Self.normalizedPath($0) }.filter { seen.insert($0).inserted }
            try requireExisting(standardized)
            let tracked = Dictionary(
                (previous?.sources ?? []).map { ($0.path, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            // Seeding names folders; a connected Notion workspace stays.
            let notion = (previous?.sources ?? []).filter(\.isNotion)
            return try sync(
                sources: standardized.map { tracked[$0] ?? CorpusSource(path: $0) } + notion,
                options: options,
                excluded: previous?.excluded ?? []
            )
        }
    }

    /// Adds `newPaths` to whatever is already tracked (existing sources keep
    /// their original `addedAt`) and re-syncs the whole corpus.
    @discardableResult
    public func addSources(
        _ newPaths: [String],
        options: CorpusExtractionOptions? = nil
    ) throws -> CorpusVocabulary {
        try FileLock.withLock(at: paths.corpusVocabularyLockFile) {
            let previous = try load()
            let standardized = newPaths.map { Self.normalizedPath($0) }
            var sources = previous?.sources ?? []
            let existingPaths = Set(sources.map(\.path))
            try requireExisting(standardized.filter { !existingPaths.contains($0) })
            for path in standardized where !existingPaths.contains(path) {
                sources.append(CorpusSource(path: path))
            }
            return try sync(
                sources: sources,
                options: options ?? previous?.options ?? .default,
                excluded: previous?.excluded ?? []
            )
        }
    }

    /// Stops tracking `pathsToRemove` and re-syncs the remainder. Returns
    /// `nil` (and clears corpus.json) when nothing is left tracked.
    @discardableResult
    public func removeSources(_ pathsToRemove: [String]) throws -> CorpusVocabulary? {
        try FileLock.withLock(at: paths.corpusVocabularyLockFile) {
            guard let previous = try load() else { return nil }
            let standardized = Set(
                pathsToRemove.map { Self.normalizedPath($0) }
            )
            let remaining = previous.sources.filter { !standardized.contains($0.path) }
            guard !remaining.isEmpty else {
                try remove()
                return nil
            }
            return try sync(sources: remaining, options: previous.options, excluded: previous.excluded)
        }
    }
}
