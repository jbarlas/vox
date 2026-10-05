import Foundation
import XCTest

@testable import VoxKit

/// Answers Notion requests from a routing closure and records every request.
private final class StubTransport: NotionTransport, @unchecked Sendable {
    struct Reply {
        var status = 200
        var json: Any = [String: Any]()
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var route: (_ method: String, _ path: String, _ body: [String: Any]?) -> Reply

    init(route: @escaping (_ method: String, _ path: String, _ body: [String: Any]?) -> Reply) {
        self.route = route
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    /// Request paths relative to the API root, query included.
    var paths: [String] {
        requests.map { request in
            let url = request.url!
            let path = url.path.replacingOccurrences(of: "/v1/", with: "")
            return url.query.map { "\(path)?\($0)" } ?? path
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let url = request.url!
        var path = url.path.replacingOccurrences(of: "/v1/", with: "")
        if let query = url.query { path += "?\(query)" }
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let reply = route(request.httpMethod ?? "GET", path, body)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (try JSONSerialization.data(withJSONObject: reply.json), response)
    }
}

/// Records requested sleeps instead of sleeping.
private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _sleeps: [Duration] = []
    var sleeps: [Duration] { lock.withLock { _sleeps } }
    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in lock.withLock { _sleeps.append(duration) } }
    }
}

private func text(_ value: String) -> [[String: Any]] {
    [["plain_text": value]]
}

private func page(_ id: String, title: String, edited: String = "2020-01-01T00:00:00.000Z", extra: [String: Any] = [:])
    -> [String: Any]
{
    var properties: [String: Any] = ["Name": ["type": "title", "title": text(title)]]
    for (key, value) in extra { properties[key] = value }
    return ["object": "page", "id": id, "last_edited_time": edited, "properties": properties]
}

private func block(_ type: String, _ value: String, id: String = UUID().uuidString, children: Bool = false)
    -> [String: Any]
{
    ["id": id, "type": type, "has_children": children, type: ["rich_text": text(value)]]
}

private func list(_ results: [[String: Any]], next: String? = nil) -> [String: Any] {
    var json: [String: Any] = ["results": results, "has_more": next != nil]
    if let next { json["next_cursor"] = next }
    return json
}

final class NotionVocabularyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vox-notion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var paths: VoxPaths { VoxPaths(supportDirectory: root.appendingPathComponent("support")) }
    private var cache: URL { paths.notionCacheDirectory }

    private func client(_ transport: StubTransport, sleeps: SleepRecorder = SleepRecorder()) -> NotionClient {
        NotionClient(
            token: "secret-test-token",
            tokenEnvVar: "NOTION_TOKEN",
            transport: transport,
            minimumInterval: .zero,
            sleep: sleeps.sleep
        )
    }

    private func syncer(_ transport: StubTransport, now: Date = Date()) -> NotionSyncer {
        NotionSyncer(client: client(transport), cacheDirectory: cache, now: { now })
    }

    private func cached(_ id: String) throws -> String {
        try String(contentsOf: cache.appendingPathComponent("\(id).md"), encoding: .utf8)
    }

    // MARK: Markdown

    func testBlocksBecomeMarkdownAndCodeIsFenced() {
        XCTAssertEqual(NotionMarkdown.line(for: block("heading_1", "Roadmap")), "# Roadmap")
        XCTAssertEqual(NotionMarkdown.line(for: block("bulleted_list_item", "Ship Zorblatt")), "- Ship Zorblatt")
        XCTAssertEqual(NotionMarkdown.line(for: block("paragraph", "Plain")), "Plain")
        XCTAssertEqual(NotionMarkdown.line(for: block("code", "let x = 1")), "```\nlet x = 1\n```")
        XCTAssertEqual(NotionMarkdown.line(for: block("some_future_type", "Still text")), "Still text")
        XCTAssertNil(NotionMarkdown.line(for: block("paragraph", "")))
        XCTAssertEqual(
            NotionMarkdown.line(for: ["type": "child_page", "child_page": ["title": "Quuxfoo spec"]]),
            "Quuxfoo spec"
        )
        XCTAssertEqual(
            NotionMarkdown.line(for: ["type": "table_row", "table_row": ["cells": [text("Owner"), text("Wes")]]]),
            "Owner | Wes"
        )
        XCTAssertEqual(
            NotionMarkdown.line(for: ["type": "image", "image": ["caption": text("Blimpwax diagram")]]),
            "Blimpwax diagram"
        )
    }

    func testPropertiesKeepWordsAndDropNumbersAndDates() {
        let row = page(
            "p1",
            title: "Launch",
            extra: [
                "Team": ["type": "select", "select": ["name": "Platform"]],
                "Tags": ["type": "multi_select", "multi_select": [["name": "Zorblatt"], ["name": "Quuxfoo"]]],
                "Owner": ["type": "people", "people": [["name": "Wes"]]],
                "Notes": ["type": "rich_text", "rich_text": text("Blimpwax")],
                "Stage": ["type": "status", "status": ["name": "Drafting"]],
                "Points": ["type": "number", "number": 3],
            ]
        )
        XCTAssertEqual(NotionMarkdown.title(of: row), "Launch")
        XCTAssertEqual(
            NotionMarkdown.propertyLines(of: row),
            ["Notes: Blimpwax", "Owner: Wes", "Stage: Drafting", "Tags: Zorblatt, Quuxfoo", "Team: Platform"]
        )
    }

    // MARK: Sync

    func testSyncPaginatesAndDescendsIntoNestedBlocksButNotChildPages() async throws {
        let transport = StubTransport { method, path, body in
            switch (method, path) {
            case ("POST", "search"):
                return body?["start_cursor"] == nil
                    ? .init(json: list([page("p1", title: "Zorblatt")], next: "c2"))
                    : .init(json: list([page("p2", title: "Quuxfoo")]))
            case ("GET", "blocks/p1/children?page_size=100"):
                return .init(json: list([block("paragraph", "First"), block("toggle", "Toggle", id: "t1", children: true)], next: "b2"))
            case ("GET", "blocks/p1/children?page_size=100&start_cursor=b2"):
                return .init(json: list([
                    ["id": "cp", "type": "child_page", "has_children": true, "child_page": ["title": "Sub page"]]
                ]))
            case ("GET", "blocks/t1/children?page_size=100"):
                return .init(json: list([block("paragraph", "Nested")]))
            case ("GET", "blocks/p2/children?page_size=100"):
                return .init(json: list([]))
            default:
                return .init(status: 500, json: ["message": "unexpected \(method) \(path)"])
            }
        }
        let report = try await syncer(transport).sync()

        XCTAssertEqual(report.pagesFetched, 2)
        XCTAssertEqual(try cached("p1"), "# Zorblatt\n\nFirst\n\nToggle\n\nNested\n\nSub page\n")
        XCTAssertEqual(try cached("p2"), "# Quuxfoo\n")
        XCTAssertFalse(transport.paths.contains { $0.hasPrefix("blocks/cp") }, "child pages arrive via search")

        let first = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(first.value(forHTTPHeaderField: "Authorization"), "Bearer secret-test-token")
        XCTAssertEqual(first.value(forHTTPHeaderField: "Notion-Version"), NotionClient.apiVersion)
    }

    func testRefreshSkipsUnchangedRefetchesEditedAndRemovesDeleted() async throws {
        var pages = [page("p1", title: "Zorblatt"), page("p2", title: "Quuxfoo")]
        var bodies = ["p1": "one", "p2": "two"]
        let transport = StubTransport { method, path, _ in
            if method == "POST" { return .init(json: list(pages)) }
            let id = path.components(separatedBy: "/")[1]
            return .init(json: list([block("paragraph", bodies[id] ?? "")]))
        }
        let now = Date()
        try await syncer(transport, now: now).sync()
        XCTAssertEqual(transport.paths.filter { $0.hasPrefix("blocks/") }.count, 2)

        // p1 edited, p2 unchanged, p3 new.
        pages = [
            page("p1", title: "Zorblatt", edited: "2021-01-01T00:00:00.000Z"),
            page("p2", title: "Quuxfoo"),
            page("p3", title: "Blimpwax"),
        ]
        bodies["p1"] = "one edited"
        let before = transport.paths.count
        var report = try await syncer(transport, now: now).sync()
        let fetched = transport.paths[before...].filter { $0.hasPrefix("blocks/") }
        XCTAssertEqual(Set(fetched), ["blocks/p1/children?page_size=100", "blocks/p3/children?page_size=100"])
        XCTAssertEqual(report.pagesFetched, 2)
        XCTAssertEqual(report.pagesUnchanged, 1)
        XCTAssertTrue(try cached("p1").contains("one edited"))

        // p2 deleted or unshared.
        pages.removeAll { $0["id"] as? String == "p2" }
        report = try await syncer(transport, now: now).sync()
        XCTAssertEqual(report.pagesRemoved, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("p2.md").path))
    }

    /// Notion rounds last_edited_time to the minute, so an edit in the same
    /// minute as the last sync keeps the same timestamp.
    func testPagesEditedNearTheLastSyncAreRefetched() async throws {
        let now = Date()
        let edited = ISO8601.string(from: now.addingTimeInterval(-30))
        let transport = StubTransport { method, _, _ in
            method == "POST"
                ? .init(json: list([page("p1", title: "Zorblatt", edited: edited)]))
                : .init(json: list([block("paragraph", "body")]))
        }
        try await syncer(transport, now: now).sync()
        let report = try await syncer(transport, now: now.addingTimeInterval(10)).sync()
        XCTAssertEqual(report.pagesFetched, 1)
        XCTAssertEqual(report.pagesUnchanged, 0)
    }

    func testArchivedAndInvisiblePagesAreSkipped() async throws {
        let transport = StubTransport { method, path, _ in
            if method == "POST" {
                var archived = page("gone", title: "Old")
                archived["in_trash"] = true
                return .init(json: list([page("p1", title: "Zorblatt"), page("hidden", title: "Hidden"), archived]))
            }
            if path.hasPrefix("blocks/hidden") { return .init(status: 404, json: ["message": "Could not find block"]) }
            return .init(json: list([]))
        }
        let report = try await syncer(transport).sync()
        XCTAssertEqual(report.pagesFetched, 1)
        XCTAssertEqual(report.pagesSkipped, 1)
        XCTAssertFalse(transport.paths.contains { $0.hasPrefix("blocks/gone") })
    }

    func testCacheDirectoryIsOwnerOnly() async throws {
        let transport = StubTransport { _, _, _ in .init(json: list([])) }
        try await syncer(transport).sync()
        let mode = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    // MARK: Client

    func testRateLimitWaitsRetryAfterThenSucceeds() async throws {
        var calls = 0
        let transport = StubTransport { _, _, _ in
            calls += 1
            return calls == 1
                ? .init(status: 429, json: ["message": "rate limited"], headers: ["Retry-After": "2"])
                : .init(json: list([]))
        }
        let sleeps = SleepRecorder()
        _ = try await client(transport, sleeps: sleeps).searchPages(startCursor: nil)
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(sleeps.sleeps.contains(.seconds(2)), "\(sleeps.sleeps)")
    }

    func testServerErrorsBackOffAndEventuallyFail() async throws {
        let transport = StubTransport { _, _, _ in .init(status: 502, json: ["message": "bad gateway"]) }
        let sleeps = SleepRecorder()
        do {
            _ = try await client(transport, sleeps: sleeps).searchPages(startCursor: nil)
            XCTFail("expected failure")
        } catch let error as VoxError {
            XCTAssertTrue(error.message.contains("502"), error.message)
        }
        XCTAssertEqual(transport.requests.count, 6, "first try plus five retries")
        XCTAssertEqual(sleeps.sleeps.filter { $0 >= .seconds(1) }, [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)])
    }

    func testRejectedTokenNamesTheVariableNotTheSecret() async throws {
        let transport = StubTransport { _, _, _ in .init(status: 401, json: ["message": "API token is invalid."]) }
        do {
            _ = try await client(transport).searchPages(startCursor: nil)
            XCTFail("expected failure")
        } catch let error as VoxError {
            XCTAssertTrue(error.message.contains("$NOTION_TOKEN"), error.message)
            XCTAssertFalse("\(error.message) \(error.detail ?? "")".contains("secret-test-token"))
        }
    }

    func testRequestsAreSpacedByTheMinimumInterval() async throws {
        let transport = StubTransport { _, _, _ in .init(json: list([])) }
        let sleeps = SleepRecorder()
        let spaced = NotionClient(
            token: "t", tokenEnvVar: "NOTION_TOKEN", transport: transport,
            minimumInterval: .seconds(10), sleep: sleeps.sleep
        )
        _ = try await spaced.searchPages(startCursor: nil)
        _ = try await spaced.searchPages(startCursor: nil)
        XCTAssertEqual(sleeps.sleeps.count, 1)
        XCTAssertGreaterThan(sleeps.sleeps[0], .seconds(9))
    }

    // MARK: Store integration

    private func notionWorkspace() -> StubTransport {
        StubTransport { method, _, _ in
            method == "POST"
                ? .init(json: list([page("p1", title: "Zorblatt roadmap")]))
                : .init(json: list([block("paragraph", "Zorblatt Zorblatt ships with Quuxfoo Quuxfoo.")]))
        }
    }

    private func makeFolder(_ name: String, _ body: String) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try body.write(to: folder.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)
        return folder
    }

    func testConnectTracksNotionAndSeedKeepsIt() async throws {
        let store = CorpusVocabularyStore(paths: paths)
        let (vocabulary, report) = try await NotionVocabulary.connect(
            store: store, environment: ["NOTION_TOKEN": "t"], transport: notionWorkspace()
        )
        XCTAssertEqual(report.pagesFetched, 1)
        let source = try XCTUnwrap(vocabulary.sources.first)
        XCTAssertEqual(source.kind, .notion)
        XCTAssertEqual(source.tokenEnvVar, "NOTION_TOKEN")
        XCTAssertTrue(vocabulary.terms.map(\.term).contains("Zorblatt"))

        let folder = try makeFolder("notes", "Blimpwax Blimpwax")
        let seeded = try store.replaceSources([folder.path], options: .default)
        XCTAssertEqual(seeded.sources.map(\.isNotion), [false, true], "seed replaces folders, keeps Notion")
        XCTAssertEqual(Set(seeded.terms.map(\.term)), ["Blimpwax", "Zorblatt", "Quuxfoo"])
    }

    func testConnectWithoutTokenFailsBeforeAnyRequest() async throws {
        let transport = notionWorkspace()
        do {
            _ = try await NotionVocabulary.connect(store: CorpusVocabularyStore(paths: paths), environment: [:], transport: transport)
            XCTFail("expected failure")
        } catch let error as VoxError {
            XCTAssertTrue(error.message.contains("NOTION_TOKEN"), error.message)
            XCTAssertTrue(error.detail?.contains("launchctl setenv") == true)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// A broken Notion connection must not stop local folders from syncing.
    func testRefreshSyncsFoldersWhenNotionFails() async throws {
        let store = CorpusVocabularyStore(paths: paths)
        try await NotionVocabulary.connect(store: store, environment: ["NOTION_TOKEN": "t"], transport: notionWorkspace())
        let folder = try makeFolder("notes", "Blimpwax Blimpwax")
        try store.addSources([folder.path])

        let down = StubTransport { _, _, _ in .init(status: 401, json: ["message": "revoked"]) }
        let result = try await NotionVocabulary.refresh(store: store, environment: ["NOTION_TOKEN": "t"], transport: down)
        XCTAssertNotNil(result.notionError)
        XCTAssertNil(result.notion)
        let terms = Set(try XCTUnwrap(result.vocabulary).terms.map(\.term))
        XCTAssertTrue(terms.isSuperset(of: ["Blimpwax", "Zorblatt"]), "folder synced, cached Notion pages kept")
    }

    func testDisconnectAndClearDeleteTheCache() async throws {
        let store = CorpusVocabularyStore(paths: paths)
        try await NotionVocabulary.connect(store: store, environment: ["NOTION_TOKEN": "t"], transport: notionWorkspace())
        let folder = try makeFolder("notes", "Blimpwax Blimpwax")
        try store.addSources([folder.path])

        let remaining = try XCTUnwrap(try store.untrackNotion())
        XCTAssertEqual(remaining.sources.map(\.path), [folder.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))

        try await NotionVocabulary.connect(store: store, environment: ["NOTION_TOKEN": "t"], transport: notionWorkspace())
        try store.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertFalse(store.exists)
    }

    func testISO8601ParsesNotionTimestamps() {
        XCTAssertNotNil(ISO8601.date(from: "2026-10-05T12:34:00.000Z"))
        XCTAssertNotNil(ISO8601.date(from: "2026-10-05T12:34:00Z"))
    }
}
