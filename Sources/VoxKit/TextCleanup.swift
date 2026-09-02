import Foundation

/// Deterministic transcript tidying for the `cleanup` mode.
///
/// Rule-based on purpose: it is instant, offline, and never rephrases the
/// user's words — anything that requires judgement belongs in an LLM mode.
public enum TextCleanup {
    /// Standalone filler tokens, removed wherever they appear.
    static let fillerWords: Set<String> = [
        "um", "uh", "erm", "uhh", "umm", "hmm", "mhm", "eh", "ah", "er",
    ]

    /// Words and phrases that are filler only in some contexts ("so, like, we
    /// should" vs. "I like that idea"). They are removed only when whisper's
    /// punctuation sets them off as a parenthetical — see
    /// `removeContextualFillers`. Multi-word entries are matched as a whole.
    static let contextualFillers: [[String]] = [
        ["you", "know"], ["i", "mean"], ["kind", "of"], ["sort", "of"],
        ["like"], ["so"], ["okay"], ["alright"],
    ]

    private static let sentenceEnders = CharacterSet(charactersIn: ".!?;:")
    private static let wrappingPunctuation = CharacterSet(charactersIn: ",.!?;:-—…\"'")

    /// Phrases whisper.cpp emits for non-speech audio.
    static let noiseAnnotations: [String] = [
        "[BLANK_AUDIO]", "[SILENCE]", "(silence)", "[MUSIC]", "(music)",
        "[INAUDIBLE]", "[NOISE]",
    ]

    public static func clean(_ text: String) -> String {
        var result = text
        for annotation in noiseAnnotations {
            result = result.replacingOccurrences(of: annotation, with: " ", options: .caseInsensitive)
        }
        result = removeFillerWords(from: result)
        result = removeContextualFillers(from: result)
        result = collapseRepeatedWords(in: result)
        result = normalizeWhitespaceAndPunctuation(result)
        return capitalizeSentences(result)
    }

    static func removeFillerWords(from text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false)
        let kept = tokens.filter { token in
            let bare = bareWord(of: String(token))
            guard !bare.isEmpty else { return true }
            return !fillerWords.contains(bare)
        }
        return kept.joined(separator: " ")
    }

    /// Removes a run of `contextualFillers` only when it is set off by
    /// punctuation on both sides, which is how whisper renders a spoken pause:
    ///
    /// - sentence-initial and followed by a comma: "So, like, we should" → "we should"
    /// - between commas: "it was, like, broken" → "it was broken"
    /// - after a comma and ending the sentence: "fix it, you know." → "fix it."
    ///
    /// Anything else ("I like that idea", "so far", "that kind of thing") is
    /// left alone: a missed filler reads better than a mangled sentence.
    static func removeContextualFillers(from text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var output: [String] = []
        var index = 0
        while index < tokens.count {
            guard let runEnd = contextualFillerRun(in: tokens, startingAt: index) else {
                output.append(tokens[index])
                index += 1
                continue
            }
            let lastToken = tokens[runEnd - 1]
            let trailing = trailingPunctuation(of: lastToken)
            let followedByComma = trailing.hasPrefix(",")
            let endsSentence =
                runEnd == tokens.count
                || trailing.unicodeScalars.first.map(sentenceEnders.contains) == true
            let previousTrailing = output.last.map(trailingPunctuation(of:)) ?? ""
            let precededByComma = previousTrailing.hasSuffix(",")
            let precededByBoundary =
                output.isEmpty
                || previousTrailing.unicodeScalars.last.map(sentenceEnders.contains) == true

            if precededByComma, followedByComma || endsSentence {
                let previous = output.removeLast()
                let carried = followedByComma ? String(trailing.dropFirst()) : trailing
                output.append(String(previous.dropLast()) + carried)
                index = runEnd
            } else if precededByBoundary, followedByComma {
                let carried = String(trailing.dropFirst())
                if !carried.isEmpty, let previous = output.popLast() {
                    output.append(previous + carried)
                }
                index = runEnd
            } else {
                output.append(tokens[index])
                index += 1
            }
        }
        return output.joined(separator: " ")
    }

    /// Longest run of contextual fillers starting at `start`, as the index one
    /// past its last token, or nil if `tokens[start]` begins no filler. Only
    /// the run's final token may carry trailing punctuation.
    private static func contextualFillerRun(in tokens: [String], startingAt start: Int) -> Int? {
        var end = start
        while end < tokens.count {
            guard let length = contextualFillerLength(in: tokens, at: end) else { break }
            end += length
            if !trailingPunctuation(of: tokens[end - 1]).isEmpty { break }
        }
        return end > start ? end : nil
    }

    private static func contextualFillerLength(in tokens: [String], at index: Int) -> Int? {
        for phrase in contextualFillers {
            guard index + phrase.count <= tokens.count else { continue }
            let matches = phrase.indices.allSatisfy { offset in
                let token = tokens[index + offset]
                let isLast = offset == phrase.count - 1
                if !isLast, !trailingPunctuation(of: token).isEmpty { return false }
                if offset > 0, !leadingPunctuation(of: token).isEmpty { return false }
                return bareWord(of: token) == phrase[offset]
            }
            if matches { return phrase.count }
        }
        return nil
    }

    private static func bareWord(of token: String) -> String {
        token.trimmingCharacters(in: wrappingPunctuation).lowercased()
    }

    private static func leadingPunctuation(of token: String) -> String {
        String(token.unicodeScalars.prefix(while: wrappingPunctuation.contains))
    }

    private static func trailingPunctuation(of token: String) -> String {
        let scalars = token.unicodeScalars.reversed().prefix(while: wrappingPunctuation.contains)
        return String(String.UnicodeScalarView(scalars.reversed()))
    }

    /// Collapses the stutter whisper.cpp produces on false starts ("the the").
    static func collapseRepeatedWords(in text: String) -> String {
        var output: [String] = []
        for token in text.split(separator: " ", omittingEmptySubsequences: true) {
            let word = String(token)
            let comparable = word.lowercased()
            if let previous = output.last?.lowercased(),
                previous == comparable,
                comparable.rangeOfCharacter(from: .letters) != nil
            {
                continue
            }
            output.append(word)
        }
        return output.joined(separator: " ")
    }

    static func normalizeWhitespaceAndPunctuation(_ text: String) -> String {
        var result = text
        // Space before punctuation, left behind by filler removal.
        for mark in [",", ".", "!", "?", ";", ":"] {
            result = result.replacingOccurrences(of: " \(mark)", with: mark)
        }
        // Duplicated punctuation, e.g. ",." after dropping a filler.
        result = result.replacingOccurrences(
            of: "([,;:])\\s*([.!?])", with: "$2",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "\\s+", with: " ",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func capitalizeSentences(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for character in text {
            if capitalizeNext, character.isLetter {
                result.append(Character(character.uppercased()))
                capitalizeNext = false
            } else {
                result.append(character)
                if character == "." || character == "!" || character == "?" {
                    capitalizeNext = true
                }
            }
        }
        return result
    }
}
