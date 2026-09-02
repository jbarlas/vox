import Foundation

/// Turns the vocabulary list — user terms plus any corpus-seeded ones — into
/// whisper.cpp's `initial_prompt`.
///
/// This is true decoder biasing rather than post-hoc find/replace: the terms
/// condition the decode itself, so "Kubernetes" is more likely to be *heard*
/// correctly instead of being repaired afterwards.
public enum VocabInjector {
    /// whisper.cpp truncates the prompt to the model's context window; keeping
    /// well under it avoids silently dropping terms and wasting decode budget.
    public static let maxPromptCharacters = 900

    /// The prompt for `entries` as merged by `VocabularyEntry.merge`: user
    /// terms lead, so they are what survives truncation.
    public static func initialPrompt(entries: [VocabularyEntry], extra: String? = nil) -> String? {
        initialPrompt(vocabulary: entries.map(\.term), extra: extra)
    }

    public static func initialPrompt(vocabulary: [String], extra: String? = nil) -> String? {
        let terms = normalize(vocabulary)
        var components: [String] = []
        if !terms.isEmpty {
            components.append("Glossary: " + terms.joined(separator: ", ") + ".")
        }
        if let extra = extra?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            components.append(extra)
        }
        guard !components.isEmpty else { return nil }
        return truncate(components.joined(separator: " "))
    }

    /// Trims, de-duplicates case-insensitively, and preserves the user's order
    /// so the most important terms survive truncation.
    public static func normalize(_ vocabulary: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in vocabulary {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// Truncates on a term boundary rather than mid-word, which would otherwise
    /// bias the decoder toward a word fragment.
    static func truncate(_ prompt: String, limit: Int = maxPromptCharacters) -> String {
        guard prompt.count > limit else { return prompt }
        let clipped = String(prompt.prefix(limit))
        if let lastSeparator = clipped.lastIndex(of: ",") {
            return String(clipped[clipped.startIndex..<lastSeparator]) + "."
        }
        return clipped
    }
}
