import XCTest
@testable import Zentty

@MainActor
final class WorklaneStoreServerTests: XCTestCase {
    private let worklaneID = WorklaneID("worklane-main")
    private let paneA = PaneID("pane-a")
    private let paneB = PaneID("pane-b")

    func test_focused_pane_server_drives_primary_server() throws {
        let store = makeStore()
        store.register(server: try server(origin: "http://localhost:3000", paneID: paneA, updatedAt: date(100)))
        store.register(server: try server(origin: "http://localhost:5173", paneID: paneB, updatedAt: date(200)))

        store.focusPane(id: paneB)

        XCTAssertEqual(store.activeServerContext.primaryServer?.origin, "http://localhost:5173")
        XCTAssertEqual(store.activeServerContext.focusedPaneID, paneB)
    }

    func test_worklane_level_server_surfaces_when_no_focused_pane_server() throws {
        let store = makeStore()
        store.register(server: try server(origin: "http://localhost:8080", paneID: nil, updatedAt: date(100)))

        XCTAssertNil(store.activeServerContext.primaryServer?.paneID)
        XCTAssertEqual(store.activeServerContext.primaryServer?.confidence, .worklane)
        XCTAssertEqual(store.activeServerContext.primaryServer?.origin, "http://localhost:8080")
    }

    func test_pane_close_clears_server_registrations() throws {
        let store = makeStore()
        store.register(server: try server(origin: "http://localhost:3000", paneID: paneA, updatedAt: date(100)))
        store.register(server: try server(origin: "http://localhost:5173", paneID: paneB, updatedAt: date(200)))

        XCTAssertEqual(store.closePane(id: paneA), .closed)

        XCTAssertEqual(store.activeServerContext.servers.map(\.origin), ["http://localhost:5173"])
    }

    func test_registering_server_emits_server_detection_invalidation() throws {
        let store = makeStore()
        var changes: [WorklaneChange] = []
        let subscription = store.subscribe { changes.append($0) }
        addTeardownBlock { store.unsubscribe(subscription) }

        store.register(server: try server(origin: "http://localhost:3000", paneID: paneA, updatedAt: date(100)))

        XCTAssertTrue(changes.contains { change in
            guard case .auxiliaryStateUpdated(let worklaneID, let paneID, let impacts) = change else {
                return false
            }

            return worklaneID == self.worklaneID
                && paneID == self.paneA
                && impacts.contains(.serverDetection)
        })
    }

    func test_replacing_passive_servers_only_replaces_matching_source() throws {
        let store = makeStore()
        store.register(server: try server(origin: "http://localhost:3000", paneID: paneA, source: .manual, updatedAt: date(100)))
        store.register(server: try server(origin: "http://localhost:5173", paneID: paneA, source: .scanner, updatedAt: date(200)))

        store.replacePassiveServers(
            worklaneID: worklaneID,
            source: .scanner,
            servers: [
                try server(origin: "http://localhost:8080", paneID: paneB, source: .scanner, updatedAt: date(300)),
            ]
        )

        XCTAssertEqual(
            Set(store.activeServerContext.servers.map(\.origin)),
            Set(["http://localhost:3000", "http://localhost:8080"])
        )
    }

    func test_clearing_source_for_pane_preserves_other_sources_and_panes() throws {
        let store = makeStore()
        store.register(server: try server(origin: "http://localhost:3000", paneID: paneA, source: .manual, updatedAt: date(100)))
        store.register(server: try server(origin: "http://localhost:5173", paneID: paneA, source: .watch, updatedAt: date(200)))
        store.register(server: try server(origin: "http://localhost:8080", paneID: paneB, source: .watch, updatedAt: date(300)))
        store.register(server: try server(origin: "http://localhost:4000", paneID: nil, source: .scanner, updatedAt: date(400)))

        store.clearServers(worklaneID: worklaneID, paneID: paneA, source: .watch)

        XCTAssertEqual(
            Set(store.activeServerContext.servers.map(\.origin)),
            Set([
                "http://localhost:3000",
                "http://localhost:8080",
                "http://localhost:4000",
            ])
        )
    }

    func test_clearing_passive_sources_preserves_manual_and_watch_servers() throws {
        let store = makeStore()
        store.register(server: try server(origin: "http://localhost:3000", paneID: paneA, source: .manual, updatedAt: date(100)))
        store.register(server: try server(origin: "http://localhost:5173", paneID: paneA, source: .watch, updatedAt: date(200)))
        store.register(server: try server(origin: "http://localhost:8080", paneID: paneB, source: .scanner, updatedAt: date(300)))
        store.register(server: try server(origin: "http://localhost:4000", paneID: nil, source: .docker, updatedAt: date(400)))

        store.clearPassiveServers(worklaneID: worklaneID)

        XCTAssertEqual(
            Set(store.activeServerContext.servers.map(\.origin)),
            Set([
                "http://localhost:3000",
                "http://localhost:5173",
            ])
        )
    }

    func test_remembered_server_becomes_primary_until_it_disappears() throws {
        let store = makeStore()
        let proxy = try server(origin: "http://localhost:4568", paneID: paneA, source: .scanner, updatedAt: date(200))
        let app = try server(origin: "http://localhost:4567", paneID: paneA, source: .scanner, updatedAt: date(100))
        store.register(server: proxy)
        store.register(server: app)

        // Equal relevance scores → deterministic origin-ascending tiebreak picks 4567.
        XCTAssertEqual(store.activeServerContext.primaryServer?.origin, "http://localhost:4567")

        // Session selection outranks every other signal.
        store.rememberPrimaryServer(proxy)

        XCTAssertEqual(store.activeServerContext.primaryServer?.origin, "http://localhost:4568")

        store.clearServers(worklaneID: worklaneID, paneID: paneA, source: .scanner)

        XCTAssertNil(store.activeServerContext.primaryServer)
    }


    private func makeStore() -> WorklaneStore {
        let store = WorklaneStore()
        store.replaceWorklanes([
            WorklaneState(
                id: worklaneID,
                title: nil,
                paneStripState: PaneStripState(
                    panes: [
                        PaneState(id: paneA, title: "server"),
                        PaneState(id: paneB, title: "frontend"),
                    ],
                    focusedPaneID: paneA
                )
            )
        ], activeWorklaneID: worklaneID)
        return store
    }

    private func server(
        origin: String,
        paneID: PaneID?,
        source: DetectedServerSource = .manual,
        updatedAt: Date
    ) throws -> DetectedServer {
        let candidate = try ServerURLNormalizer.normalize(origin)
        return DetectedServer(
            id: "test:\(origin):\(paneID?.rawValue ?? "worklane")",
            origin: candidate.origin,
            url: candidate.url,
            display: candidate.display,
            worklaneID: worklaneID,
            paneID: paneID,
            source: source,
            ports: [candidate.port],
            confidence: paneID == nil ? .worklane : .explicit,
            updatedAt: updatedAt
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
