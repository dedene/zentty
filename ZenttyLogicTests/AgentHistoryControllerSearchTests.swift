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
