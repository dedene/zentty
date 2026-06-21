import XCTest
@testable import Zentty

final class ServerMenuModelTests: XCTestCase {
    func test_visible_excludes_ignored_ports_and_lists_them_as_hidden() throws {
        let model = ServerMenuModel(context: context(
            [
                try server("http://localhost:5173/"),
                try server("http://localhost:9229/"),
            ],
            ignored: ["9229"]
        ))

        XCTAssertEqual(model.visible.map { $0.server.origin }, ["http://localhost:5173"])
        XCTAssertEqual(model.hidden.map { $0.server.origin }, ["http://localhost:9229"])
        XCTAssertEqual(model.hidden.first?.port, 9229)
    }

    func test_hidden_is_empty_without_ignored_ports() throws {
        let model = ServerMenuModel(context: context([try server("http://localhost:5173/")]))

        XCTAssertTrue(model.hidden.isEmpty)
        XCTAssertFalse(model.isEmpty)
    }

    func test_manageable_excludes_manual_servers() throws {
        let model = ServerMenuModel(context: context([
            try server("http://localhost:5173/", source: .scanner),
            try server("http://localhost:3000/", source: .manual),
        ]))

        XCTAssertEqual(model.manageable.map { $0.server.origin }, ["http://localhost:5173"])
        XCTAssertEqual(model.manageable.first?.port, 5173)
    }

    func test_exactly_one_visible_entry_is_primary() throws {
        let model = ServerMenuModel(context: context([
            try server("http://localhost:5173/", source: .manual),
            try server("http://localhost:3000/", source: .scanner),
        ]))

        XCTAssertEqual(model.visible.first { $0.isPrimary }?.server.origin, "http://localhost:5173")
        XCTAssertEqual(model.visible.filter { $0.isPrimary }.count, 1)
    }

    func test_isStoppable_is_true_only_for_scanner_servers_attributed_by_pid() throws {
        XCTAssertTrue(ServerMenuModel.isStoppable(
            try server("http://localhost:5173/", source: .scanner, confidence: .pid)
        ))
        XCTAssertFalse(ServerMenuModel.isStoppable(
            try server("http://localhost:3000/", source: .scanner, confidence: .cwd)
        ))
        XCTAssertFalse(ServerMenuModel.isStoppable(
            try server("http://localhost:4000/", source: .docker, confidence: .pid)
        ))
        XCTAssertFalse(ServerMenuModel.isStoppable(
            try server("http://localhost:6006/", source: .manual, confidence: .explicit)
        ))
    }

    func test_is_empty_with_no_servers() {
        let model = ServerMenuModel(context: context([]))

        XCTAssertTrue(model.isEmpty)
        XCTAssertTrue(model.visible.isEmpty)
        XCTAssertTrue(model.hidden.isEmpty)
    }

    func test_hidden_only_context_is_not_empty() throws {
        let model = ServerMenuModel(context: context(
            [try server("http://localhost:9229/")],
            ignored: ["9229"]
        ))

        XCTAssertFalse(model.isEmpty)
        XCTAssertTrue(model.visible.isEmpty)
        XCTAssertTrue(model.manageable.isEmpty)
        XCTAssertEqual(model.hidden.map { $0.server.origin }, ["http://localhost:9229"])
    }

    // MARK: - Helpers

    private func context(_ servers: [DetectedServer], ignored: [String] = []) -> WorklaneServerContext {
        let relevance = ServerRelevanceContext(
            ignoredPortRules: ServerPortRule.normalize(ignored),
            now: Date(timeIntervalSince1970: 10_000)
        )
        let ranked = ServerRelevance.rank(servers, context: relevance)
        return WorklaneServerContext(
            worklaneID: WorklaneID("wl"),
            focusedPaneID: nil,
            ranked: ranked
        )
    }

    private func server(
        _ rawURL: String,
        source: DetectedServerSource = .scanner,
        confidence: DetectedServerConfidence = .pid
    ) throws -> DetectedServer {
        let candidate = try ServerURLNormalizer.normalize(rawURL)
        return DetectedServer(
            id: "id-\(candidate.origin)-\(source.rawValue)",
            origin: candidate.origin,
            url: candidate.url,
            display: candidate.display,
            worklaneID: WorklaneID("wl"),
            paneID: nil,
            source: source,
            ports: [candidate.port],
            confidence: confidence,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
