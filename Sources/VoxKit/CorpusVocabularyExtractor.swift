import Foundation

/// Finds the words a corpus uses far more than general English does — the
/// project names, jargon, and proper nouns Whisper is least likely to know.
///
/// Fully offline: the only reference is `ReferenceWordFrequencies`, compiled in.
///
/// Scoring is a smoothed log-odds ratio against that reference:
///
///     score(w) = log2( (count(w) / N) / p_ref(w) )
///
/// where `N` is the corpus token count and `p_ref(w)` is the word's share of
/// the reference corpus, floored at half the rarest embedded entry for words
/// the reference has never seen. Terms under `minScore` (default 2 bits: at
/// least 4x as common here as in general English) are dropped, as are terms
/// under `minCount` and `minLength`.
/// The top `maxTerms` by score survive; ties break on count, then spelling.
///
/// Runtime is linear in corpus size — about 30 MB of text per second in a
/// release build on a modest Linux VM — so a large Obsidian vault (a few
/// thousand notes, tens of MB) finishes in seconds.
public struct CorpusVocabularyExtractor: Sendable {
    public static let supportedExtensions: Set<String> = ["md", "txt"]

    public struct Result: Sendable, Equatable {
        public var terms: [CorpusTerm]
        public var filesScanned: Int
        public var tokensScanned: Int
    }

    public let options: CorpusExtractionOptions

    public init(options: CorpusExtractionOptions = .default) {
        self.options = options
    }

    /// Every `.md`/`.txt` file at or under `paths`, sorted for stable output.
    /// Hidden directories (`.obsidian`, `.git`) are skipped.
    public static func textFiles(under paths: [URL], fileManager: FileManager = .default) throws -> [URL] {
        var files: [URL] = []
        for path in paths {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
                throw VoxError.config("No such file or directory: \(path.path)")
            }
            guard isDirectory.boolValue else {
                if supportedExtensions.contains(path.pathExtension.lowercased()) {
                    files.append(path)
                }
                continue
            }
            guard
                let enumerator = fileManager.enumerator(
                    at: path,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else { continue }
            for case let url as URL in enumerator {
                guard supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                files.append(url)
            }
        }
        var seen = Set<String>()
        return files.filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.path < $1.path }
    }

    /// Reads and scores `files`. Unreadable or non-UTF-8 files are skipped
    /// rather than failing the whole run; `onProgress` gets the running count.
    public func extract(files: [URL], onProgress: ((Int) -> Void)? = nil) throws -> Result {
        try options.validate()
        var counter = TermCounter(options: options)
        var scanned = 0
        for file in files {
            guard let data = try? Data(contentsOf: file),
                let text = String(data: data, encoding: .utf8)
            else { continue }
            counter.ingest(text)
            scanned += 1
            onProgress?(scanned)
        }
        return Result(terms: counter.rank(), filesScanned: scanned, tokensScanned: counter.totalTokens)
    }

    public func extract(text: String) throws -> Result {
        try options.validate()
        var counter = TermCounter(options: options)
        counter.ingest(text)
        return Result(terms: counter.rank(), filesScanned: 1, tokensScanned: counter.totalTokens)
    }

    /// Splits text into candidate terms: runs of letters and digits, allowing
    /// `.`, `-`, `'`, `_` between them and `+`/`#` after them, so `whisper.cpp`,
    /// `C++`, `O'Brien`, and `ggml-base` survive as single tokens. URLs and
    /// fenced Markdown code blocks are skipped wholesale — they are syntax, not
    /// vocabulary the user will dictate.
    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        forEachToken(in: text) { tokens.append($0) }
        return tokens
    }

    static func forEachToken(in text: String, _ body: (String) -> Void) {
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        let end = scalars.endIndex
        var inFence = false
        var atLineStart = true

        while index < end {
            let scalar = scalars[index]

            if atLineStart, scalar == "`", isFenceOpener(scalars, at: index) {
                inFence.toggle()
                index = skipLine(scalars, from: index)
                atLineStart = true
                continue
            }
            atLineStart = scalar == "\n"
            if inFence || !isWordScalar(scalar) {
                index = scalars.index(after: index)
                continue
            }

            // A word run, possibly containing internal connectors.
            let start = index
            var lastWordEnd = scalars.index(after: index)
            index = lastWordEnd
            while index < end {
                let current = scalars[index]
                if isWordScalar(current) || isSuffixSymbol(current) {
                    index = scalars.index(after: index)
                    lastWordEnd = index
                } else if isConnector(current) {
                    let next = scalars.index(after: index)
                    guard next < end, isWordScalar(scalars[next]) else { break }
                    index = next
                } else {
                    break
                }
            }
            // `://` right after a run means it was a URL scheme: drop it and
            // everything up to the next whitespace.
            if isURLScheme(scalars, after: lastWordEnd) {
                index = skipToWhitespace(scalars, from: lastWordEnd)
                atLineStart = false
                continue
            }
            body(String(scalars[start..<lastWordEnd]))
            atLineStart = false
        }
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 128 {
            return (value >= 0x61 && value <= 0x7A) || (value >= 0x41 && value <= 0x5A)
                || (value >= 0x30 && value <= 0x39)
        }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    private static func isConnector(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case ".", "-", "'", "_", "\u{2019}": return true
        default: return false
        }
    }

    /// `+` and `#` may also end a word: `C++`, `C#`, `F#`.
    private static func isSuffixSymbol(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "+" || scalar == "#"
    }

    private static func isFenceOpener(_ scalars: String.UnicodeScalarView, at index: String.UnicodeScalarView.Index) -> Bool {
        var cursor = index
        var count = 0
        while cursor < scalars.endIndex, scalars[cursor] == "`" {
            count += 1
            cursor = scalars.index(after: cursor)
        }
        return count >= 3
    }

    private static func isURLScheme(
        _ scalars: String.UnicodeScalarView,
        after index: String.UnicodeScalarView.Index
    ) -> Bool {
        var cursor = index
        for expected in [":", "/", "/"] as [Unicode.Scalar] {
            guard cursor < scalars.endIndex, scalars[cursor] == expected else { return false }
            cursor = scalars.index(after: cursor)
        }
        return true
    }

    private static func skipLine(
        _ scalars: String.UnicodeScalarView,
        from index: String.UnicodeScalarView.Index
    ) -> String.UnicodeScalarView.Index {
        var cursor = index
        while cursor < scalars.endIndex, scalars[cursor] != "\n" {
            cursor = scalars.index(after: cursor)
        }
        return cursor < scalars.endIndex ? scalars.index(after: cursor) : cursor
    }

    private static func skipToWhitespace(
        _ scalars: String.UnicodeScalarView,
        from index: String.UnicodeScalarView.Index
    ) -> String.UnicodeScalarView.Index {
        var cursor = index
        while cursor < scalars.endIndex, !scalars[cursor].properties.isWhitespace {
            cursor = scalars.index(after: cursor)
        }
        return cursor
    }
}

/// Accumulates token counts across files, then scores them.
struct TermCounter {
    private struct Entry {
        var count = 0
        /// Surface forms seen for this lowercased key, so the most common
        /// casing wins ("LiteLLM" over "litellm" when the corpus prefers it).
        var forms: [String: Int] = [:]
    }

    let options: CorpusExtractionOptions
    private var entries: [String: Entry] = [:]
    private(set) var totalTokens = 0

    init(options: CorpusExtractionOptions) {
        self.options = options
    }

    mutating func ingest(_ text: String) {
        CorpusVocabularyExtractor.forEachToken(in: text) { token in
            totalTokens += 1
            guard token.unicodeScalars.count >= options.minLength, !isNumeric(token) else { return }
            let key = token.lowercased()
            entries[key, default: Entry()].count += 1
            entries[key]!.forms[token, default: 0] += 1
        }
    }

    func rank() -> [CorpusTerm] {
        guard totalTokens > 0 else { return [] }
        let reference = ReferenceWordFrequencies.shares
        let floor = ReferenceWordFrequencies.unseenShare
        let total = Double(totalTokens)

        var scored: [CorpusTerm] = []
        scored.reserveCapacity(entries.count)
        for (key, entry) in entries where entry.count >= options.minCount {
            let corpusShare = Double(entry.count) / total
            let referenceShare = reference[key] ?? floor
            let score = log2(corpusShare / referenceShare)
            guard score >= options.minScore else { continue }
            let form = entry.forms.max { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
            }!.key
            scored.append(CorpusTerm(term: form, score: score, count: entry.count))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.term < rhs.term
        }
        return Array(scored.prefix(options.maxTerms))
    }

    private func isNumeric(_ token: String) -> Bool {
        token.unicodeScalars.allSatisfy { $0.properties.numericType != nil || $0 == "." || $0 == "-" }
    }
}

extension ReferenceWordFrequencies {
    /// Lowercased word → share of the reference corpus. Parsed from `table` on
    /// first use, which only ever happens inside `vox vocab seed`/`refresh`.
    static let shares: [String: Double] = {
        var result: [String: Double] = [:]
        result.reserveCapacity(32_000)
        for line in table.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let space = line.firstIndex(of: " "), let thousands = Double(line[line.index(after: space)...])
            else { continue }
            result[String(line[..<space])] = thousands * 1000 / totalTokens
        }
        return result
    }()

    /// Share assumed for a word the reference never saw: half of its rarest
    /// entry, so unknown words rank as rarer than anything listed but not
    /// infinitely so.
    static let unseenShare: Double = {
        let smallest = shares.values.min() ?? (1 / totalTokens)
        return smallest / 2
    }()
}
