import Foundation
import XCTest
@testable import Zentty

/// The controller's search engine (SE-W): absent while Agent History is off, built over the
/// running index's readers once the indexer starts, reused while it runs, gone again when it
/// stops. Temp paths, fake sources, no real agent directories.
@MainActor
final class AgentHistoryControllerSearchTests: XCTestCase {
    private func makeController() -> AgentHistoryController {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-search-\(UUID().uuidString)", isDirectory: true)
        let paths = AgentHistoryPaths(directoryURL: base.appendingPathComponent("AgentHistory", isDirectory: true))
        let claudeRoot = base.appendingPathComponent("claude-root", isDirectory: true)
        try? FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        let claude = FakeHistorySource(agent: .claude, rootPath: claudeRoot.path)
        claude.setUnits([
            .single("claude-zebra", messages: ["where is the zebra migration", "in db/migrate"],
                    title: "Zebra migration", cwd: "/work/project"),
            .single("claude-other", cwd: "/work/project"),
        ])
        let sources: [any AgentHistorySource] = [claude]
        let controller = AgentHistoryController(
            launchDelay: 0,
            makeSources: { sources },
            makeIndexer: { storage, stateStore, configuration, callbacks in
                AgentHistoryIndexer(
                    storage: storage,
                    stateStore: stateStore,
                    makeSources: { sources },
                    configuration: configuration,
                    systemConditions: FakeSystemConditions(),
                    onStatusChange: callbacks.onStatusChange,
                    onSnapshotChange: callbacks.onSnapshotChange
                )
            }
        )
        let configStore = AppConfigStore(fileURL: base.appendingPathComponent("config.toml", isDirectory: false))
        controller.configure(configStore: configStore, paths: paths)
        addTeardownBlock { @MainActor in
            controller.stop()
            try? FileManager.default.removeItem(at: base)
        }
        return controller
    }

    private func launch(_ controller: AgentHistoryController) -> Bool {
        let decided = expectation(description: "launch decision")
        var started = false
        controller.scheduleStartAfterLaunch { result in
            started = result
            decided.fulfill()
        }
        wait(for: [decided], timeout: 5)
        return started
    }

    private func waitForStatus(
        _ controller: AgentHistoryController,
        _ description: String,
        where predicate: @escaping (AgentHistoryStatus) -> Bool
    ) {
        if predicate(controller.status) {
            return
        }
        let reached = expectation(description: description)
        var fulfilled = false
        let id = controller.addStatusObserver { status in
            if !fulfilled, predicate(status) {
                fulfilled = true
                reached.fulfill()
            }
        }
        wait(for: [reached], timeout: 10)
        controller.removeObserver(id)
    }

    private func waitForSessions(_ controller: AgentHistoryController, count: Int) {
        if controller.metadataSnapshot.sessions.count == count {
            return
        }
        let reached = expectation(description: "\(count) sessions indexed")
        var fulfilled = false
        let id = controller.addSnapshotObserver { snapshot in
            if !fulfilled, snapshot.sessions.count == count {
                fulfilled = true
                reached.fulfill()
            }
        }
        wait(for: [reached], timeout: 10)
        controller.removeObserver(id)
    }

    func test_search_engine_nil_when_disabled_and_available_after_start() throws {
        let controller = makeController()
        XCTAssertFalse(launch(controller), "no consent yet")
        XCTAssertNil(controller.searchEngine, "off: no engine")

        controller.enable(agents: [.claude])
        waitForStatus(controller, "watching") { $0.state == .watching }
        waitForSessions(controller, count: 2)

        let engine = try XCTUnwrap(controller.searchEngine, "running: engine over the index")
        XCTAssertTrue(engine === controller.searchEngine, "built once and reused")
        XCTAssertTrue(engine.readers === controller.storage?.readers, "reads through the storage's reader pool")
        XCTAssertEqual(engine.tokenizer, controller.storage?.tokenizer)
        XCTAssertEqual(engine.enabledAgents, [.claude], "gates on the persisted agent selection")

        // The metadata tier reads the controller's live snapshot.
        let query = HistoryQueryParser.parse("zebra")
        let context = HistorySearchContext(scope: .all)
        let metadata = engine.metadataIndex.search(query, context: context)
        XCTAssertEqual(metadata.results.map(\.session.nativeID), ["claude-zebra"])

        // The content tier reads the index off the main thread.
        let searched = expectation(description: "content search")
        let found = LockedValue<[String]?>(nil)
        HistorySearchEngine.queue.async {
            let response = try? engine.searchContent(
                HistoryQueryParser.parse("migrate"),
                context: context,
                excludingSessionIDs: [],
                cancellation: HistorySearchCancellation()
            )
            found.set(response?.results.map(\.session.nativeID))
            searched.fulfill()
        }
        wait(for: [searched], timeout: 10)
        XCTAssertEqual(found.get(), ["claude-zebra"])

        // Turning Agent History off hides the engine again (the index is kept).
        controller.setEnabled(false)
        waitForStatus(controller, "off") { $0.state == .off && !$0.isEnabled }
        XCTAssertNil(controller.searchEngine, "off again: no engine")
    }

    // MARK: - An engine handed out before History goes off (G2-2)

    /// Starts History, waits for both sessions, and returns the engine and the zebra session.
    private func runningEngine(_ controller: AgentHistoryController) throws -> (HistorySearchEngine, Int64) {
        XCTAssertFalse(launch(controller), "no consent yet")
        controller.enable(agents: [.claude])
        waitForStatus(controller, "watching") { $0.state == .watching }
        waitForSessions(controller, count: 2)
        let engine = try XCTUnwrap(controller.searchEngine)
        let session = try XCTUnwrap(controller.metadataSnapshot.sessions.first { $0.nativeID == "claude-zebra" })
        XCTAssertEqual(try engine.preview(sessionID: session.id, query: HistoryQueryParser.parse("")).session.nativeID,
                       "claude-zebra", "reads while running")
        return (engine, session.id)
    }

    /// Every read of a stale engine throws `.indexUnavailable("off")` or finds nothing.
    private func assertServesNothing(_ engine: HistorySearchEngine, session: Int64, _ label: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let query = HistoryQueryParser.parse("migrate")
        func assertNoData<T>(_ read: String, _ body: () throws -> T, isEmpty: (T) -> Bool) {
            do {
                let value = try body()
                XCTAssertTrue(isEmpty(value), "\(label): \(read) served \(value)", file: file, line: line)
            } catch {
                XCTAssertEqual(error as? HistorySearchError, .indexUnavailable("off"), "\(label): \(read)",
                               file: file, line: line)
            }
        }
        let searched = expectation(description: "\(label): content search")
        let outcome = LockedValue<Result<HistoryContentResponse, Error>?>(nil)
        HistorySearchEngine.queue.async {
            outcome.set(Result {
                try engine.searchContent(query, context: HistorySearchContext(scope: .all), excludingSessionIDs: [],
                                         cancellation: HistorySearchCancellation())
            })
            searched.fulfill()
        }
        wait(for: [searched], timeout: 10)
        assertNoData("content search", { try XCTUnwrap(outcome.get()).get() }, isEmpty: { $0.results.isEmpty })
        assertNoData("preview", { try engine.preview(sessionID: session, query: query) }, isEmpty: { _ in false })
        assertNoData("transcript", { try engine.transcript(sessionID: session, query: query) },
                     isEmpty: { $0.turns.isEmpty })
        assertNoData("last turns", { try engine.lastTurns(sessionID: session, limit: 5) },
                     isEmpty: { $0.turns.isEmpty })
        assertNoData("sessions", { try engine.sessions(nativeID: "claude-zebra", agent: nil, scope: .all) },
                     isEmpty: { $0.isEmpty })
        XCTAssertTrue(engine.metadataIndex.search(query, context: HistorySearchContext(scope: .all)).results.isEmpty,
                      "\(label): metadata tier", file: file, line: line)
    }

    func test_engine_issued_before_turning_off_serves_nothing_until_turned_on_again() throws {
        let controller = makeController()
        let (engine, session) = try runningEngine(controller)

        controller.setEnabled(false)
        waitForStatus(controller, "off") { $0.state == .off && !$0.isEnabled }
        controller.drainControlQueueForTesting()
        assertServesNothing(engine, session: session, "turned off")
        XCTAssertEqual(engine.readers.openConnectionCountForTesting, 0, "no reader reopened while off")

        controller.setEnabled(true)
        waitForStatus(controller, "watching again") { $0.state == .watching }
        XCTAssertTrue(engine === controller.searchEngine, "same storage, same engine")
        XCTAssertEqual(try engine.preview(sessionID: session, query: HistoryQueryParser.parse("")).session.nativeID,
                       "claude-zebra", "on again: reads again")
    }

    func test_engine_issued_before_delete_index_serves_nothing() throws {
        let controller = makeController()
        let (engine, session) = try runningEngine(controller)

        let deleted = expectation(description: "deleted")
        var outcome: AgentHistoryDisableOutcome?
        controller.disable(deleteIndex: true) {
            outcome = $0
            deleted.fulfill()
        }
        wait(for: [deleted], timeout: 10)
        XCTAssertEqual(outcome, .deleted)
        assertServesNothing(engine, session: session, "index deleted")
        XCTAssertEqual(engine.readers.openConnectionCountForTesting, 0)
    }
}

/// A lock-guarded value the test hands across threads.
private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
