import XCTest
@testable import Zentty

final class ServerRelevanceTests: XCTestCase {
    private let p1 = PaneID("p1")
    private let p2 = PaneID("p2")

    // MARK: - Ignored-port hiding

    func test_ignored_port_non_manual_is_hidden() throws {
        let ranked = ServerRelevance.rank(
            [try server("http://localhost:9229/", source: .scanner)],
            context: context(ignored: ["9229"])
        )

        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.tier, .hidden)
        XCTAssertTrue(ranked.first?.reasons.contains(.ignoredPort(9229)) == true)
    }

    func test_ignored_port_manual_remains_visible() throws {
        let ranked = ServerRelevance.rank(
            [try server("http://localhost:9229/", source: .manual)],
            context: context(ignored: ["9229"])
        )

        XCTAssertEqual(ranked.first?.tier, .primary)
        XCTAssertTrue(ranked.first?.reasons.contains(.manual) == true)
    }

    func test_hidden_server_is_never_primary() throws {
        let ranked = ServerRelevance.rank(
            [
                try server("http://localhost:9229/", source: .scanner),
                try server("http://localhost:5173/", source: .scanner),
            ],
            context: context(ignored: ["9229"])
        )

        XCTAssertEqual(ranked.first { $0.tier == .primary }?.server.origin, "http://localhost:5173")
        XCTAssertEqual(ranked.first { $0.server.origin == "http://localhost:9229" }?.tier, .hidden)
    }

    func test_all_ignored_yields_no_primary() throws {
        let ranked = ServerRelevance.rank(
            [
                try server("http://localhost:9229/", source: .scanner),
                try server("http://localhost:24678/", source: .scanner),
            ],
            context: context(ignored: ["9229", "24678"])
        )

        XCTAssertNil(ranked.first { $0.tier == .primary })
        XCTAssertTrue(ranked.allSatisfy { $0.tier == .hidden })
    }

    // MARK: - Ordering

    func test_session_selected_visible_server_wins_primary() throws {
        let ranked = ServerRelevance.rank(
            [
                try server("http://localhost:3000/", source: .manual, paneID: p1),
                try server("http://localhost:5173/", source: .scanner),
            ],
            context: context(focused: p1, running: [p1], session: "http://localhost:5173")
        )

        XCTAssertEqual(ranked.first?.tier, .primary)
        XCTAssertEqual(ranked.first?.server.origin, "http://localhost:5173")
        XCTAssertTrue(ranked.first?.reasons.contains(.sessionSelected) == true)
    }

    func test_focused_running_server_beats_idle_source_priority() throws {
        let ranked = ServerRelevance.rank(
            [
                try server("http://localhost:5173/", source: .scanner, paneID: p1),
                try server("http://localhost:3000/", source: .watch, paneID: p2),
            ],
            context: context(focused: p1, running: [p1])
        )

        XCTAssertEqual(ranked.first?.server.origin, "http://localhost:5173")
        XCTAssertTrue(ranked.first?.reasons.contains(.focusedPane) == true)
        XCTAssertTrue(ranked.first?.reasons.contains(.runningPane) == true)
    }

    func test_source_then_confidence_order_in_equal_activity() throws {
        let ranked = ServerRelevance.rank(
            [
                try server("http://localhost:3000/", source: .scanner, confidence: .pid),
                try server("http://localhost:5173/", source: .docker, confidence: .cwd),
            ],
            context: context()
        )

        // docker (40) + cwd (10) = 50 beats scanner (0) + pid (20) = 20.
        XCTAssertEqual(ranked.first?.server.origin, "http://localhost:5173")
    }

    func test_equal_score_breaks_by_origin_ascending() throws {
        let ranked = ServerRelevance.rank(
            [
                try server("http://localhost:5173/", source: .scanner, confidence: .pid),
                try server("http://localhost:3000/", source: .scanner, confidence: .pid),
            ],
            context: context()
        )

        XCTAssertEqual(ranked.first?.server.origin, "http://localhost:3000")
    }

    func test_exactly_one_primary_when_visible_candidates_exist() throws {
        let ranked = ServerRelevance.rank(
            [
                try server("http://localhost:3000/", source: .scanner),
                try server("http://localhost:5173/", source: .scanner),
                try server("http://localhost:8080/", source: .scanner),
            ],
            context: context()
        )

        XCTAssertEqual(ranked.filter { $0.tier == .primary }.count, 1)
        XCTAssertEqual(ranked.filter { $0.tier == .shown }.count, 2)
    }

    func test_empty_input_returns_empty_output() {
        XCTAssertTrue(ServerRelevance.rank([], context: context()).isEmpty)
    }

    // MARK: - Freshness

    func test_fresh_window_adds_reason_and_breaks_ties() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let fresh = try server("http://localhost:5173/", source: .scanner, firstSeenAt: now.addingTimeInterval(-30))
        let stale = try server("http://localhost:3000/", source: .scanner, firstSeenAt: now.addingTimeInterval(-120))

        let ranked = ServerRelevance.rank([stale, fresh], context: context(now: now))

        XCTAssertTrue(ranked.first { $0.server.origin == "http://localhost:5173" }?.reasons.contains(.fresh) == true)
        XCTAssertFalse(ranked.first { $0.server.origin == "http://localhost:3000" }?.reasons.contains(.fresh) == true)
        XCTAssertEqual(ranked.first?.server.origin, "http://localhost:5173")
    }

    // MARK: - Helpers

    private func server(
        _ rawURL: String,
        source: DetectedServerSource = .scanner,
        paneID: PaneID? = nil,
        confidence: DetectedServerConfidence = .pid,
        firstSeenAt: Date = Date(timeIntervalSince1970: 0)
    ) throws -> DetectedServer {
        let candidate = try ServerURLNormalizer.normalize(rawURL)
        return DetectedServer(
            id: "id-\(candidate.origin)-\(source.rawValue)-\(paneID?.rawValue ?? "wl")",
            origin: candidate.origin,
            url: candidate.url,
            display: candidate.display,
            worklaneID: WorklaneID("wl"),
            paneID: paneID,
            source: source,
            ports: [candidate.port],
            confidence: confidence,
            updatedAt: firstSeenAt,
            firstSeenAt: firstSeenAt
        )
    }

    private func context(
        focused: PaneID? = nil,
        running: Set<PaneID> = [],
        ignored: [String] = [],
        session: String? = nil,
        now: Date = Date(timeIntervalSince1970: 10_000)
    ) -> ServerRelevanceContext {
        ServerRelevanceContext(
            focusedPaneID: focused,
            runningPaneIDs: running,
            ignoredPortRules: ServerPortRule.normalize(ignored),
            sessionSelectedOrigin: session,
            now: now
        )
    }
}
