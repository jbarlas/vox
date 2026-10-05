import Foundation

/// Turns Notion pages into Markdown files the corpus extractor scans like any
/// other notes folder. Only text matters for scoring, so this keeps titles,
/// property values and block text, and fences code so the extractor skips it.
public enum NotionMarkdown {
    /// Blocks nested deeper than this are not fetched. Real documents rarely
    /// go past a handful of levels; the cap bounds a pathological page.
    static let maxDepth = 12

    public static func title(of page: NotionObject) -> String {
        let properties = page["properties"] as? [String: NotionObject] ?? [:]
        for property in properties.values where property["type"] as? String == "title" {
            return plainText(property["title"])
        }
        return ""
    }

    /// `Name: value` lines for the property types that carry words: titles,
    /// text, selects, statuses and people. Numbers, dates and checkboxes add
    /// nothing to a vocabulary.
    public static func propertyLines(of page: NotionObject) -> [String] {
        let properties = page["properties"] as? [String: NotionObject] ?? [:]
        return properties.keys.sorted().compactMap { name in
            guard let property = properties[name], let type = property["type"] as? String, type != "title" else {
                return nil
            }
            let value: String
            switch type {
            case "rich_text":
                value = plainText(property["rich_text"])
            case "select", "status":
                value = (property[type] as? NotionObject)?["name"] as? String ?? ""
            case "multi_select":
                value = (property["multi_select"] as? [NotionObject] ?? []).compactMap { $0["name"] as? String }
                    .joined(separator: ", ")
            case "people":
                value = (property["people"] as? [NotionObject] ?? []).compactMap { $0["name"] as? String }
                    .joined(separator: ", ")
            default:
                return nil
            }
            return value.isEmpty ? nil : "\(name): \(value)"
        }
    }

    /// One block as Markdown. Unknown block types still contribute whatever
    /// `rich_text` they carry, so a new Notion block type degrades to text
    /// rather than disappearing.
    public static func line(for block: NotionObject) -> String? {
        guard let type = block["type"] as? String else { return nil }
        let content = block[type] as? NotionObject ?? [:]
        switch type {
        case "code":
            let text = plainText(content["rich_text"])
            return text.isEmpty ? nil : "```\n\(text)\n```"
        case "child_page", "child_database":
            // Their own content arrives through search as separate pages.
            let title = content["title"] as? String ?? ""
            return title.isEmpty ? nil : title
        case "table_row":
            let cells = content["cells"] as? [Any] ?? []
            let text = cells.map { plainText($0) }.filter { !$0.isEmpty }.joined(separator: " | ")
            return text.isEmpty ? nil : text
        default:
            var text = plainText(content["rich_text"])
            let caption = plainText(content["caption"])
            if !caption.isEmpty { text += text.isEmpty ? caption : " \(caption)" }
            guard !text.isEmpty else { return nil }
            switch type {
            case "heading_1": return "# \(text)"
            case "heading_2": return "## \(text)"
            case "heading_3": return "### \(text)"
            case "bulleted_list_item", "to_do": return "- \(text)"
            case "numbered_list_item": return "1. \(text)"
            case "quote", "callout": return "> \(text)"
            default: return text
            }
        }
    }

    /// Whether a block's children belong to this page's text. Child pages and
    /// databases are fetched on their own.
    static func shouldDescend(into block: NotionObject) -> Bool {
        guard block["has_children"] as? Bool == true, let type = block["type"] as? String else { return false }
        return type != "child_page" && type != "child_database"
    }

    static func plainText(_ value: Any?) -> String {
        guard let segments = value as? [NotionObject] else { return "" }
        return segments.compactMap { $0["plain_text"] as? String }.joined()
    }

    public static func document(title: String, properties: [String], body: [String]) -> String {
        var lines: [String] = []
        if !title.isEmpty { lines.append("# \(title)") }
        if !properties.isEmpty { lines.append(properties.joined(separator: "\n")) }
        lines.append(contentsOf: body)
        return lines.joined(separator: "\n\n") + "\n"
    }
}

/// What one Notion fetch did.
public struct NotionSyncReport: Sendable, Equatable {
    public var pagesFetched = 0
    public var pagesUnchanged = 0
    public var pagesRemoved = 0
    /// Pages search listed but whose content was no longer visible by the
    /// time it was fetched. Skipped, not fatal.
    public var pagesSkipped = 0

    public init() {}

    public var pagesTotal: Int { pagesFetched + pagesUnchanged }
}

/// Mirrors every page shared with the integration into `cacheDirectory` as
/// `<page id>.md`, plus `index.json` recording each page's `last_edited_time`.
///
/// Refresh is incremental: an unchanged page is not re-fetched. Notion rounds
/// `last_edited_time` to the minute, so a page edited in the same minute as the
/// previous sync looks unchanged; pages edited within `recentWindow` of the
/// previous sync are re-fetched to cover that.
///
/// Removal only happens after a complete search, so a failed or partial fetch
/// never deletes cached pages.
public struct NotionSyncer {
    static let indexFileName = "index.json"
    static let recentWindow: TimeInterval = 120

    let client: NotionClient
    let cacheDirectory: URL
    let fileManager: FileManager
    let now: () -> Date

    public init(
        client: NotionClient,
        cacheDirectory: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.cacheDirectory = cacheDirectory
        self.fileManager = fileManager
        self.now = now
    }

    struct Index: Codable, Equatable {
        var syncedAt: Date?
        var pages: [String: Entry] = [:]

        struct Entry: Codable, Equatable {
            var lastEditedTime: String
            var title: String
        }
    }

    public func sync(onProgress: ((NotionSyncReport) -> Void)? = nil) async throws -> NotionSyncReport {
        try prepareCacheDirectory()
        let started = now()
        let previous = loadIndex()
        var index = Index(syncedAt: started)
        var report = NotionSyncReport()

        var pages: [NotionObject] = []
        var cursor: String?
        repeat {
            let page = try await client.searchPages(startCursor: cursor)
            pages.append(contentsOf: page.results)
            cursor = page.nextCursor
        } while cursor != nil

        for page in pages {
            guard let id = page["id"] as? String,
                let lastEdited = page["last_edited_time"] as? String,
                page["archived"] as? Bool != true,
                page["in_trash"] as? Bool != true
            else { continue }
            let file = fileURL(for: id)
            let title = NotionMarkdown.title(of: page)

            if let cached = previous.pages[id], cached.lastEditedTime == lastEdited,
                !isRecent(lastEdited, since: previous.syncedAt), fileManager.fileExists(atPath: file.path)
            {
                index.pages[id] = cached
                report.pagesUnchanged += 1
                onProgress?(report)
                continue
            }

            guard let body = try await blockLines(of: id, depth: 0) else {
                report.pagesSkipped += 1
                continue
            }
            let text = NotionMarkdown.document(
                title: title,
                properties: NotionMarkdown.propertyLines(of: page),
                body: body
            )
            try Data(text.utf8).write(to: file, options: .atomic)
            index.pages[id] = Index.Entry(lastEditedTime: lastEdited, title: title)
            report.pagesFetched += 1
            onProgress?(report)
        }

        // Search was complete, so anything cached and not listed was deleted,
        // trashed or unshared.
        for id in Set(previous.pages.keys).subtracting(index.pages.keys) {
            try? fileManager.removeItem(at: fileURL(for: id))
            report.pagesRemoved += 1
        }
        try saveIndex(index)
        return report
    }

    /// `nil` when the page itself is no longer visible.
    private func blockLines(of blockID: String, depth: Int) async throws -> [String]? {
        var lines: [String] = []
        var cursor: String?
        repeat {
            guard let page = try await client.blockChildren(of: blockID, startCursor: cursor) else {
                return depth == 0 ? nil : lines
            }
            for block in page.results {
                if let line = NotionMarkdown.line(for: block) { lines.append(line) }
                if NotionMarkdown.shouldDescend(into: block), depth < NotionMarkdown.maxDepth,
                    let childID = block["id"] as? String,
                    let children = try await blockLines(of: childID, depth: depth + 1)
                {
                    lines.append(contentsOf: children)
                }
            }
            cursor = page.nextCursor
        } while cursor != nil
        return lines
    }

    private func isRecent(_ lastEdited: String, since syncedAt: Date?) -> Bool {
        guard let syncedAt, let edited = ISO8601.date(from: lastEdited) else { return true }
        return edited >= syncedAt.addingTimeInterval(-Self.recentWindow)
    }

    func fileURL(for pageID: String) -> URL {
        let safe = pageID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return cacheDirectory.appendingPathComponent("\(safe).md")
    }

    /// The cache holds company documents in plain text: owner-only access.
    private func prepareCacheDirectory() throws {
        try fileManager.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDirectory.path)
    }

    private func loadIndex() -> Index {
        let url = cacheDirectory.appendingPathComponent(Self.indexFileName)
        guard let data = try? Data(contentsOf: url) else { return Index() }
        return (try? VoxJSON.decoder().decode(Index.self, from: data)) ?? Index()
    }

    private func saveIndex(_ index: Index) throws {
        let url = cacheDirectory.appendingPathComponent(Self.indexFileName)
        try VoxJSON.encoder(pretty: true).encode(index).write(to: url, options: .atomic)
    }
}

/// Glue between the Notion fetch and the corpus store, shared by the CLI and
/// Settings.
public enum NotionVocabulary {
    public static let defaultTokenEnvVar = "NOTION_TOKEN"

    public static func token(
        envVar: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        guard let token = environment[envVar]?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw VoxError.config(
                "$\(envVar) is not set",
                detail: "Set it to your Notion integration's secret. The menu bar app needs "
                    + "`launchctl setenv \(envVar) …`, since it does not read your shell's profile."
            )
        }
        return token
    }

    /// Fetches the workspace into the cache, then tracks it as a source.
    @discardableResult
    public static func connect(
        store: CorpusVocabularyStore,
        tokenEnvVar: String = defaultTokenEnvVar,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: NotionTransport = URLSessionNotionTransport(),
        onProgress: ((NotionSyncReport) -> Void)? = nil
    ) async throws -> (CorpusVocabulary, NotionSyncReport) {
        let client = NotionClient(
            token: try token(envVar: tokenEnvVar, environment: environment),
            tokenEnvVar: tokenEnvVar,
            transport: transport
        )
        let report = try await NotionSyncer(client: client, cacheDirectory: store.paths.notionCacheDirectory)
            .sync(onProgress: onProgress)
        return (try store.trackNotion(tokenEnvVar: tokenEnvVar), report)
    }

    public struct RefreshResult {
        public var vocabulary: CorpusVocabulary?
        public var notion: NotionSyncReport?
        /// Set when the Notion fetch failed. Local folders were still synced,
        /// against whatever Notion pages were cached before.
        public var notionError: VoxError?
    }

    /// What `refresh` and Settings' "Sync Now" run: fetch Notion when it is
    /// tracked, then re-scan every source. A Notion failure never blocks the
    /// local folders.
    public static func refresh(
        store: CorpusVocabularyStore,
        options: CorpusExtractionOptions? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: NotionTransport = URLSessionNotionTransport(),
        onProgress: ((NotionSyncReport) -> Void)? = nil
    ) async throws -> RefreshResult {
        var result = RefreshResult()
        if let source = try store.load()?.sources.first(where: \.isNotion) {
            let envVar = source.tokenEnvVar ?? defaultTokenEnvVar
            do {
                let client = NotionClient(
                    token: try token(envVar: envVar, environment: environment),
                    tokenEnvVar: envVar,
                    transport: transport
                )
                result.notion = try await NotionSyncer(client: client, cacheDirectory: store.paths.notionCacheDirectory)
                    .sync(onProgress: onProgress)
            } catch {
                result.notionError = VoxError.wrap(error, code: .config, message: "Notion sync failed")
            }
        }
        result.vocabulary = try store.resync(options: options)
        return result
    }
}
