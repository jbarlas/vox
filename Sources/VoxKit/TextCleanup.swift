import Foundation

/// Deterministic transcript tidying for the `cleanup` mode.
///
/// Rule-based on purpose: it is instant, offline, and never rephrases the
/// user's words — anything that requires judgement belongs in an LLM mode.
public enum TextCleanup {
    /// Standalone filler tokens. Words that double as real words in other
    /// contexts (for instance "like" or "so") are deliberately excluded.
    static let fillerWords: Set<String> = [
        "um", "uh", "erm", "uhh", "umm", "hmm", "mhm", "eh", "ah", "er",
    ]

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
        result = collapseRepeatedWords(in: result)
        result = normalizeWhitespaceAndPunctuation(result)
        return capitalizeSentences(result)
    }

    static func removeFillerWords(from text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false)
        let kept = tokens.filter { token in
            let bare = token
                .trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:-—…\"'"))
                .lowercased()
            guard !bare.isEmpty else { return true }
            return !fillerWords.contains(bare)
        }
        return kept.joined(separator: " ")
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
