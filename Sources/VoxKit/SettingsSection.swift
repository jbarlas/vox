/// The sections of the app's Settings window, in sidebar order.
///
/// Lives in VoxKit (not VoxApp) so the ordering, grouping and identifiers can
/// be unit-tested without a Mac. `rawValue` is stable and safe to persist —
/// e.g. as the last-selected section — independent of the display title.
public enum SettingsSection: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case general
    case vocabulary
    case feedback
    case modes
    case llm
    case output

    public var id: String { rawValue }

    /// Sidebar group headers. A new section goes in whichever group its
    /// concern belongs to; a genuinely new concern gets a new group.
    public enum Group: String, CaseIterable, Hashable, Identifiable, Sendable {
        /// Capturing speech: model, hotkey, recording, vocabulary, feedback.
        case dictation
        /// What happens to the transcript afterwards: modes, LLM, delivery.
        case text

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .dictation: return "Dictation"
            case .text: return "Text"
            }
        }

        /// Sections in this group, in sidebar order.
        public var sections: [SettingsSection] {
            SettingsSection.allCases.filter { $0.group == self }
        }
    }

    public var group: Group {
        switch self {
        case .general, .vocabulary, .feedback: return .dictation
        case .modes, .llm, .output: return .text
        }
    }

    public var title: String {
        switch self {
        case .general: return "General"
        case .vocabulary: return "Vocabulary"
        case .feedback: return "Feedback"
        case .modes: return "Modes"
        case .llm: return "LLM"
        case .output: return "Output"
        }
    }

    /// SF Symbol name for the sidebar row.
    public var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .vocabulary: return "text.book.closed"
        case .feedback: return "speaker.wave.2"
        case .modes: return "wand.and.stars"
        case .llm: return "cloud"
        case .output: return "doc.on.clipboard"
        }
    }

    /// The section shown when the window first opens.
    public static let initial: SettingsSection = .general

    /// Resolves a persisted identifier, falling back to `initial` for an
    /// unknown or missing value (e.g. a section that has since been removed).
    public static func resolve(_ rawValue: String?) -> SettingsSection {
        rawValue.flatMap(SettingsSection.init(rawValue:)) ?? initial
    }
}
