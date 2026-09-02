import Foundation
import XCTest

@testable import VoxKit

final class CorpusVocabularyTests: XCTestCase {
    /// Ordinary prose padding, so common words have realistic counts.
    private let filler = """
        The team met in the morning to talk about the work for the week. We looked at the plan, \
        the people on the project, and the time it would take. There is a lot to do and not much \
        time, so we should be careful with what we take on and what we say no to. After the \
        meeting some of us went for coffee and talked about the new office and the weather.
        """

    private var corpus: String {
        var parts: [String] = []
        for _ in 0..<20 { parts.append(filler) }
        for _ in 0..<6 {
            parts.append(
                """
                Deployed Vox to the LiteLLM gateway; Kubernetes rollout was fine. Zorblatt asked \
                about whisper.cpp latency. LiteLLM routes to Ollama. Vox uses whisper.cpp. \
                Zorblatt owns the Kubernetes cluster.
                """
            )
        }
        return parts.joined(separator: "\n\n")
    }

    func testDistinctiveTermsOutrankCommonWords() throws {
        let result = try CorpusVocabularyExtractor().extract(text: corpus)
        let ranked = result.terms.map(\.term)

        for expected in ["Zorblatt", "LiteLLM", "Kubernetes", "whisper.cpp", "Vox", "Ollama"] {
            XCTAssertTrue(ranked.contains(expected), "\(expected) missing from \(ranked)")
        }
        // Common words: either absent or ranked below every domain term.
        let lastDomain = ["Zorblatt", "LiteLLM", "Kubernetes", "whisper.cpp", "Vox", "Ollama"]
            .compactMap { ranked.firstIndex(of: $0) }.max()!
        for common in ["the", "and", "meeting", "morning", "coffee", "time", "work", "people"] {
            if let index = ranked.firstIndex(of: common) {
                XCTAssertGreaterThan(index, lastDomain, "'\(common)' ranked above a domain term")
            }
        }
        XCTAssertFalse(ranked.contains("the"))
        XCTAssertFalse(ranked.contains("and"))
        XCTAssertTrue(result.terms.map(\.score) == result.terms.map(\.score).sorted(by: >))
    }

    func testPreservesMostCommonCasing() throws {
        let text = String(repeating: "LiteLLM litellm LiteLLM GGUF gguf GGUF gguf gguf. ", count: 5)
        let terms = try CorpusVocabularyExtractor().extract(text: text).terms
        XCTAssertEqual(terms.first { $0.term.lowercased() == "litellm" }?.term, "LiteLLM")
        XCTAssertEqual(terms.first { $0.term.lowercased() == "gguf" }?.term, "gguf")
        XCTAssertEqual(terms.first { $0.term.lowercased() == "gguf" }?.count, 25)
    }

    func testFiltersShortNumericSingletonAndCappedTerms() throws {
        let text = String(repeating: "Zorblatt ab 12 3.14 x1 Zorblatt Quux ", count: 3) + " Singleton"
        var options = CorpusExtractionOptions()
        options.maxTerms = 1
        let capped = try CorpusVocabularyExtractor(options: options).extract(text: text).terms
        XCTAssertEqual(capped.map(\.term), ["Zorblatt"])

        let all = try CorpusVocabularyExtractor().extract(text: text).terms.map(\.term)
        XCTAssertEqual(Set(all), ["Zorblatt", "Quux"])
        XCTAssertFalse(all.contains("Singleton"), "minCount should drop single occurrences")
    }

    func testTokenizerKeepsConnectorsAndSkipsURLsAndFences() {
        let text = """
            See whisper.cpp and O'Brien's ggml-base at https://github.com/ggml/whisper.cpp now.
            ```swift
            let codeNoise = FooBar()
            ```
            C++ is fine, trailing-dash- too.
            """
        let tokens = CorpusVocabularyExtractor.tokenize(text)
        XCTAssertEqual(
            tokens,
            [
                "See", "whisper.cpp", "and", "O'Brien's", "ggml-base", "at", "now",
                "C++", "is", "fine", "trailing-dash", "too",
            ]
        )
    }

    func testMergePutsUserFirstAndDropsCollisions() {
        let corpus = CorpusVocabulary(
            sources: [CorpusSource(path: "/notes")],
            terms: [
                CorpusTerm(term: "kubernetes", score: 9, count: 5),
                CorpusTerm(term: "Zorblatt", score: 8, count: 4),
                CorpusTerm(term: "Removed", score: 7, count: 3),
            ],
            excluded: ["removed"]
        )
        let merged = VocabularyEntry.merge(user: ["Kubernetes", "GGUF"], corpus: corpus)
        XCTAssertEqual(merged.map(\.term), ["Kubernetes", "GGUF", "Zorblatt"])
        XCTAssertEqual(merged.map(\.source), [.user, .user, .corpus])
        XCTAssertEqual(merged.map(\.weight), [1.0, 1.0, 0.5])
        XCTAssertEqual(
            VocabInjector.initialPrompt(entries: merged),
            "Glossary: Kubernetes, GGUF, Zorblatt."
        )
    }

    func testExcludeIsIdempotentAndReportsWhetherKnown() {
        var corpus = CorpusVocabulary(sources: [], terms: [CorpusTerm(term: "Vox", score: 1, count: 2)])
        XCTAssertTrue(corpus.exclude("vox"))
        XCTAssertTrue(corpus.exclude(" VOX "))
        XCTAssertFalse(corpus.exclude("unknown"))
        XCTAssertEqual(corpus.excluded, ["vox", "unknown"])
        XCTAssertTrue(corpus.activeTerms.isEmpty)
    }

    func testStoreRoundTripsAndToleratesMissingOrCorruptFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vox-vocab-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CorpusVocabularyStore(paths: VoxPaths(supportDirectory: directory))

        XCTAssertNil(try store.load())
        XCTAssertNil(store.loadForInference())

        let addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let vocabulary = CorpusVocabulary(
            sources: [CorpusSource(path: "/notes", addedAt: addedAt)],
            options: CorpusExtractionOptions(maxTerms: 50, minCount: 3, minLength: 3),
            filesScanned: 2,
            tokensScanned: 100,
            terms: [CorpusTerm(term: "Zorblatt", score: 8.5, count: 4)],
            excluded: ["noise"]
        )
        try store.save(vocabulary)
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded.terms, vocabulary.terms)
        XCTAssertEqual(loaded.options, vocabulary.options)
        XCTAssertEqual(loaded.excluded, ["noise"])
        XCTAssertEqual(loaded.sources, [CorpusSource(path: "/notes", addedAt: addedAt)])

        let json = try String(contentsOf: store.paths.corpusVocabularyFile, encoding: .utf8)
        XCTAssertTrue(json.contains("\"schema_version\""))
        XCTAssertTrue(json.contains("\"max_terms\""))

        try Data("not json".utf8).write(to: store.paths.corpusVocabularyFile)
        XCTAssertThrowsError(try store.load())
        XCTAssertNil(store.loadForInference())
    }

    func testDecodesLegacyStringSourcesBackfillingAddedAt() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
            {
              "schema_version": 1,
              "generated_at": "\(ISO8601.string(from: generatedAt))",
              "sources": ["/notes", "/docs"],
              "options": {"max_terms": 200, "min_count": 2, "min_length": 3, "min_score": 2},
              "files_scanned": 1,
              "tokens_scanned": 10,
              "terms": [],
              "excluded": []
            }
            """
        let vocabulary = try VoxJSON.decoder().decode(CorpusVocabulary.self, from: Data(json.utf8))
        XCTAssertEqual(vocabulary.sources.map(\.path), ["/notes", "/docs"])
        XCTAssertEqual(vocabulary.sources.map(\.addedAt), [generatedAt, generatedAt])
    }

    func testAddSourcesTracksNewFolderAndPreservesExistingAddedAt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vox-corpus-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try "Zorblatt Zorblatt".write(to: first.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "Quuxfoo Quuxfoo".write(to: second.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

        let store = CorpusVocabularyStore(paths: VoxPaths(supportDirectory: root.appendingPathComponent("support")))
        let afterFirst = try store.addSources([first.path])
        XCTAssertEqual(afterFirst.sources.map(\.path), [first.path])
        let firstAddedAt = try XCTUnwrap(afterFirst.sources.first).addedAt

        let afterSecond = try store.addSources([second.path])
        XCTAssertEqual(Set(afterSecond.sources.map(\.path)), [first.path, second.path])
        // Adding a new source re-syncs everything, but an already-tracked
        // source's addedAt must not be disturbed by that re-sync.
        let preserved = try XCTUnwrap(afterSecond.sources.first { $0.path == first.path })
        // Round-tripped through ISO-8601 (second precision), so compare at
        // that resolution rather than exact `Date` equality.
        XCTAssertEqual(ISO8601.string(from: preserved.addedAt), ISO8601.string(from: firstAddedAt))
        XCTAssertEqual(Set(afterSecond.terms.map(\.term)), ["Zorblatt", "Quuxfoo"])

        let afterRemove = try store.removeSources([first.path])
        XCTAssertEqual(afterRemove?.sources.map(\.path), [second.path])
        XCTAssertEqual(afterRemove?.terms.map(\.term), ["Quuxfoo"])

        XCTAssertNil(try store.removeSources([second.path]))
        XCTAssertFalse(store.exists)
    }

    func testExtractFromFilesScansOnlyTextFilesRecursively() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vox-corpus-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("a/b", isDirectory: true)
        let hidden = root.appendingPathComponent(".obsidian", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try "Zorblatt Zorblatt".write(to: nested.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try "Quux Quux".write(to: root.appendingPathComponent("plain.TXT"), atomically: true, encoding: .utf8)
        try "Ignored Ignored".write(to: root.appendingPathComponent("code.swift"), atomically: true, encoding: .utf8)
        try "Hidden Hidden".write(to: hidden.appendingPathComponent("h.md"), atomically: true, encoding: .utf8)

        let files = try CorpusVocabularyExtractor.textFiles(under: [root])
        XCTAssertEqual(files.map(\.lastPathComponent).sorted(), ["note.md", "plain.TXT"])

        let result = try CorpusVocabularyExtractor().extract(files: files)
        XCTAssertEqual(result.filesScanned, 2)
        XCTAssertEqual(result.tokensScanned, 4)
        XCTAssertEqual(Set(result.terms.map(\.term)), ["Zorblatt", "Quux"])

        XCTAssertThrowsError(try CorpusVocabularyExtractor.textFiles(under: [root.appendingPathComponent("missing")]))
    }

    func testSkipsVendoredDependenciesAndCMakeListsDespiteExtension() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vox-corpus-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vendored = root.appendingPathComponent("vendor/whisper.cpp", isDirectory: true)
        let build = root.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: vendored, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try "Zorblatt Zorblatt".write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try "STREQUAL STREQUAL target_link_libraries".write(
            to: vendored.appendingPathComponent("CMakeLists.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "STREQUAL STREQUAL vendored README".write(
            to: vendored.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Also a build artifact".write(
            to: build.appendingPathComponent("CMakeLists.txt"),
            atomically: true,
            encoding: .utf8
        )

        let files = try CorpusVocabularyExtractor.textFiles(under: [root])
        XCTAssertEqual(files.map(\.lastPathComponent).sorted(), ["note.md"])

        // Naming it directly is still respected: the skip only applies while
        // discovering files under a directory, not to an explicit argument.
        let direct = vendored.appendingPathComponent("CMakeLists.txt")
        XCTAssertEqual(try CorpusVocabularyExtractor.textFiles(under: [direct]), [direct])
    }

    func testModeRunnerAppendsGlossaryOnlyWhenVocabularyPresent() {
        XCTAssertEqual(ModeRunner.systemPrompt("Clean up.", vocabulary: []), "Clean up.")
        let withTerms = ModeRunner.systemPrompt("Clean up.", vocabulary: ["Vox", "vox", "LiteLLM"])
        XCTAssertTrue(withTerms.hasPrefix("Clean up.\n\n"))
        XCTAssertTrue(withTerms.hasSuffix("Vox, LiteLLM."))
    }

    func testOptionsWithoutMinScoreDecodeToDefault() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let json = Data(#"{"max_terms": 10, "min_count": 1, "min_length": 3}"#.utf8)
        let options = try decoder.decode(CorpusExtractionOptions.self, from: json)
        XCTAssertEqual(options, CorpusExtractionOptions(maxTerms: 10, minCount: 1, minLength: 3, minScore: 2))
    }

    func testReferenceTableParsesAndRanksCommonWordsHighest() {
        let shares = ReferenceWordFrequencies.shares
        XCTAssertGreaterThan(shares.count, 25_000)
        XCTAssertGreaterThan(shares["the"]!, shares["coffee"]!)
        XCTAssertGreaterThan(shares["coffee"]!, ReferenceWordFrequencies.unseenShare)
        XCTAssertNil(shares["zorblatt"])
    }
}
