import XCTest
@testable import Zentty

@MainActor
final class ServerRegistryTests: XCTestCase {
    private let worklaneID = WorklaneID("worklane-main")
    private let otherWorklaneID = WorklaneID("worklane-other")
    private let paneA = PaneID("pane-a")
    private let paneB = PaneID("pane-b")

    func test_manual_source_wins_over_scanner_for_same_origin() throws {
        let registry = ServerRegistry()

        registry.upsert(try server("http://localhost:5173/", source: .scanner, paneID: paneA, updatedAt: date(20)))
        registry.upsert(try server("http://localhost:5173/app", source: .manual, paneID: paneA, updatedAt: date(10)))

        let servers = registry.servers(in: worklaneID)

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.source, .manual)
        XCTAssertEqual(servers.first?.url.absoluteString, "http://localhost:5173/app")
        XCTAssertEqual(servers.first?.ports, [5173])
    }

    func test_focused_pane_server_is_primary_before_recent_worklane_server() throws {
        let registry = ServerRegistry()

        registry.upsert(try server("http://localhost:3000/", source: .watch, paneID: paneA, updatedAt: date(10)))
        registry.upsert(try server("http://localhost:5173/", source: .watch, paneID: paneB, updatedAt: date(20)))

        let primary = registry.primaryServer(activeWorklaneID: worklaneID, focusedPaneID: paneA)

        XCTAssertEqual(primary?.origin, "http://localhost:3000")
    }

    func test_recent_worklane_server_is_primary_when_focused_pane_has_none() throws {
        let registry = ServerRegistry()

        registry.upsert(try server("http://localhost:3000/", source: .watch, paneID: paneA, updatedAt: date(10)))
        registry.upsert(try server("http://localhost:5173/", source: .watch, paneID: paneB, updatedAt: date(20)))

        let primary = registry.primaryServer(activeWorklaneID: worklaneID, focusedPaneID: nil)

        XCTAssertEqual(primary?.origin, "http://localhost:5173")
    }

    func test_ambiguous_scanner_result_is_worklane_level() throws {
        let registry = ServerRegistry()

        registry.upsert(try server("http://localhost:4173/", source: .scanner, paneID: nil, updatedAt: date(10), confidence: .worklane))

        let servers = registry.servers(in: worklaneID)

        XCTAssertEqual(servers.count, 1)
        XCTAssertNil(servers.first?.paneID)
        XCTAssertEqual(servers.first?.confidence, .worklane)
        XCTAssertEqual(servers.first?.origin, "http://localhost:4173")
    }

    func test_clear_pane_removes_only_that_pane_servers() throws {
        let registry = ServerRegistry()

        registry.upsert(try server("http://localhost:3000/", source: .watch, paneID: paneA, updatedAt: date(10)))
        registry.upsert(try server("http://localhost:5173/", source: .watch, paneID: paneB, updatedAt: date(20)))
        registry.upsert(try server("http://localhost:4173/", source: .scanner, paneID: nil, updatedAt: date(30)))

        registry.clear(worklaneID: worklaneID, paneID: paneA)

        let origins = registry.servers(in: worklaneID).map(\.origin)
        XCTAssertEqual(origins, ["http://localhost:4173", "http://localhost:5173"])
    }

    func test_clear_pane_preserves_same_origin_from_other_pane() throws {
        let registry = ServerRegistry()

        registry.upsert(try server("http://localhost:5173/a", source: .watch, paneID: paneA, updatedAt: date(10)))
        registry.upsert(try server("http://localhost:5173/b", source: .watch, paneID: paneB, updatedAt: date(20)))

        registry.clear(worklaneID: worklaneID, paneID: paneB)

        let server = registry.server(matching: "http://localhost:5173", in: worklaneID)
        XCTAssertEqual(server?.paneID, paneA)
        XCTAssertEqual(server?.url.absoluteString, "http://localhost:5173/a")
    }

    func test_scanner_expiration_does_not_remove_manual_pin() throws {
        let registry = ServerRegistry()

        registry.upsert(try server("http://localhost:5173/", source: .scanner, paneID: paneA, updatedAt: date(10)))
        registry.upsert(try server("http://localhost:5173/pinned", source: .manual, paneID: paneA, updatedAt: date(20)))

        registry.clearSource(.scanner, worklaneID: worklaneID, paneID: nil)

        let servers = registry.servers(in: worklaneID)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.source, .manual)
        XCTAssertEqual(servers.first?.url.absoluteString, "http://localhost:5173/pinned")
    }

    func test_server_matching_accepts_origin_or_exact_url() throws {
        let registry = ServerRegistry()

        registry.upsert(try server("http://localhost:5173/docs?q=1", source: .manual, paneID: paneA, updatedAt: date(10)))

        XCTAssertEqual(registry.server(matching: "http://localhost:5173", in: worklaneID)?.origin, "http://localhost:5173")
        XCTAssertEqual(registry.server(matching: "localhost:5173/docs?q=1", in: worklaneID)?.origin, "http://localhost:5173")
    }

    func test_registry_is_scoped_by_worklane() throws {
        let registry = ServerRegistry()

        registry.upsert(try server("http://localhost:3000/", source: .watch, paneID: paneA, updatedAt: date(10)))
        registry.upsert(try server("http://localhost:5173/", worklaneID: otherWorklaneID, source: .watch, paneID: paneA, updatedAt: date(20)))

        XCTAssertEqual(registry.servers(in: worklaneID).map(\.origin), ["http://localhost:3000"])
        XCTAssertEqual(registry.servers(in: otherWorklaneID).map(\.origin), ["http://localhost:5173"])
    }

    func test_server_menu_ordering_sorts_by_display_url_without_changing_primary_choice() throws {
        let servers = [
            try server("http://localhost:4568/", source: .scanner, paneID: paneA, updatedAt: date(20)),
            try server("http://localhost:4567/", source: .scanner, paneID: paneA, updatedAt: date(30)),
            try server("http://127.0.0.1:9000/", source: .scanner, paneID: paneA, updatedAt: date(10)),
        ]

        let sorted = ServerMenuOrdering.sortedForDisplay(servers)

        XCTAssertEqual(sorted.map(\.display), [
            "localhost:4567",
            "localhost:4568",
            "localhost:9000",
        ])
        XCTAssertEqual(servers[1].origin, "http://localhost:4567")
    }

    private func server(
        _ rawURL: String,
        worklaneID: WorklaneID? = nil,
        source: DetectedServerSource,
        paneID: PaneID?,
        updatedAt: Date,
        confidence: DetectedServerConfidence = .pid
    ) throws -> DetectedServer {
        let candidate = try ServerURLNormalizer.normalize(rawURL)
        return DetectedServer(
            id: "\(worklaneID?.rawValue ?? self.worklaneID.rawValue)-\(source.rawValue)-\(candidate.origin)-\(paneID?.rawValue ?? "worklane")",
            origin: candidate.origin,
            url: candidate.url,
            display: candidate.display,
            worklaneID: worklaneID ?? self.worklaneID,
            paneID: paneID,
            source: source,
            ports: [candidate.port],
            confidence: confidence,
            updatedAt: updatedAt
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
