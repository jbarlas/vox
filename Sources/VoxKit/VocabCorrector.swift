import Foundation

/// Repairs a specific whisper.cpp failure mode `initial_prompt` alone doesn't
/// reliably prevent: a seeded compound term ("Lightswitch") comes back split
/// into its ordinary-English halves ("Light switch"). The prompt only biases
/// the decode — it is not a hard constraint — and a term made of two common
/// words often loses to the model's much stronger prior for the split form.
///
/// This runs on the transcript after decoding, independent of the prompt:
/// for every vocabulary term with no internal separator that can be split
/// into two substrings both recognized as ordinary English words (via the
/// same reference frequency table `CorpusVocabularyExtractor` scores
/// against), occurrences of the split form in the transcript are rejoined
/// into the seeded spelling.
public enum VocabCorrector {
    /// Below this, a "half" is too short to trust as a real word and not
    /// just a coincidental prefix/suffix ("id" + "ea" out of "idea").
    static let minHalfLength = 3

    /// Neither half of a split may be one of these: "cannot" splits cleanly
    /// into "can" + "not", both real words, but "can not" is itself an
    /// ordinary, frequently-spoken phrase — rejoining it would be a wrong,
    /// unintended correction, not a repaired mishear. Most other accidental
    /// splits ("sources" -> "sour" + "ces") are harmless because that exact
    /// spaced sequence never occurs in natural speech; a split on two
    /// closed-class function words is the one case that reliably does.
    static let commonFunctionWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "nor", "so", "yet", "if", "then", "than",
        "not", "no", "is", "are", "was", "were", "be", "been", "being",
        "am", "do", "does", "did", "done", "have", "has", "had",
        "can", "could", "will", "would", "shall", "should", "may", "might", "must",
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them",
        "my", "your", "his", "its", "our", "their", "this", "that", "these", "those",
        "of", "in", "on", "at", "to", "from", "by", "with", "for", "as", "into", "onto",
        "up", "down", "out", "off", "over", "under", "about", "above", "after", "before",
        "all", "any", "both", "each", "few", "more", "most", "some", "such", "only",
        "own", "same", "too", "very", "just", "also", "here", "there", "when", "where",
        "why", "how", "once", "again",
    ]

    public static func apply(vocabulary: [String], to text: String) -> String {
        let candidates = compoundCandidates(in: vocabulary)
        guard !candidates.isEmpty else { return text }
        var result = text
        for candidate in candidates {
            result = replace(candidate, in: result)
        }
        return result
    }

    struct Candidate {
        let term: String
        let first: String
        let second: String
    }

    /// One candidate per vocabulary term that both has no internal separator
    /// (already a single word, so not "GGML base") and splits cleanly into
    /// two known English words.
    static func compoundCandidates(in vocabulary: [String]) -> [Candidate] {
        var seen = Set<String>()
        var candidates: [Candidate] = []
        for term in vocabulary {
            guard term.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else { continue }
            guard seen.insert(term.lowercased()).inserted else { continue }
            guard let split = twoWordSplit(of: term) else { continue }
            candidates.append(Candidate(term: term, first: split.0, second: split.1))
        }
        return candidates
    }

    /// The first split point (scanning left to right) where both halves are
    /// in the reference table, or `nil` if the term isn't a compound of two
    /// recognized English words.
    private static func twoWordSplit(of term: String) -> (String, String)? {
        let lowered = Array(term.lowercased())
        guard lowered.count >= minHalfLength * 2 else { return nil }
        for splitIndex in minHalfLength...(lowered.count - minHalfLength) {
            let first = String(lowered[0..<splitIndex])
            let second = String(lowered[splitIndex...])
            guard !commonFunctionWords.contains(first), !commonFunctionWords.contains(second) else { continue }
            if ReferenceWordFrequencies.shares[first] != nil, ReferenceWordFrequencies.shares[second] != nil {
                return (first, second)
            }
        }
        return nil
    }

    private static func replace(_ candidate: Candidate, in text: String) -> String {
        let pattern =
            "\\b\(NSRegularExpression.escapedPattern(for: candidate.first))"
            + "\\s+\(NSRegularExpression.escapedPattern(for: candidate.second))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let template = NSRegularExpression.escapedTemplate(for: candidate.term)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
