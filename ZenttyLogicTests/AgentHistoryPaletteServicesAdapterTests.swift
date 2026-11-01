import os
import XCTest
@testable import Zentty

@MainActor
final class AgentHistoryPaletteServicesAdapterTests: XCTestCase {
    private let projectPath = "/work/project"
    private let sessionID = "11111111-2222-4333-8444-555555555555"

    // MARK: - Search

    func test_search_adapter_returns_empty_when_engine_nil() throws {
        let adapter = AgentHistorySearchAdapter(engine: { nil })
        let query = HistoryQueryParser.parse("parser crash")
        let context = HistorySearchContext(scope: .all)
        let key = AgentHistorySessionKey(agent: .claude, nativeID: sessionID)

        XCTAssertEqual(adapter.recentSessions(scope: .all, limit: 10), [])
        XCTAssertEqual(adapter.sessions(for: [key]), [])
        XCTAssertEqual(adapter.indexedSessionCount(scope: .all), 0)
        XCTAssertEqual(adapter.tokenizer(), .none)
        XCTAssertEqual(adapter.metadataHits(for: query, context: context, limit: 20).results, [])

        let contentDelivered = expectation(description: "content completion")
        var contentReturnedFirst = false
        var token: AgentHistoryCancellable?
        token = adapter.searchContent(query, context: context, excluding: []) { result in
            contentReturnedFirst = token != nil
            XCTAssertEqual(try? result.get().results, [])
            contentDelivered.fulfill()
        }

        let previewFailed = expectation(description: "preview completion")
        _ = adapter.loadPreview(7, expecting: key, query: query) { result in
            guard case .failure(HistorySearchError.indexUnavailable) = result else {
                return XCTFail("expected indexUnavailable, got \(result)")
            }
            previewFailed.fulfill()
        }

        var cancelledDelivered = false
        let cancelled = adapter.loadTranscript(7, expecting: key, query: query) { _ in cancelledDelivered = true }
        cancelled.cancel()

        wait(for: [contentDelivered, previewFailed], timeout: 2)
        XCTAssertTrue(contentReturnedFirst, "the completion never runs before the token is returned")
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertFalse(cancelledDelivered, "a cancelled load never completes")
    }

    func test_cancelled_read_waiting_on_the_queue_never_runs() {
        let queue = DispatchQueue(label: "ZenttyLogicTests.AgentHistoryAdapter.reads")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let ran = OSAllocatedUnfairLock(initialState: [Int]())
        var delivered: [Int] = []
        let lastDelivered = expectation(description: "the read that wasn't cancelled delivers")

        let stale = (0..<3).map { index in
            AgentHistorySearchAdapter.runRead(on: queue, completion: { (result: Result<Int, Error>) in
                delivered.append(index)
            }) {
                ran.withLock { $0.append(index) }
                return index
            }
        }
        let current = AgentHistorySearchAdapter.runRead(on: queue, completion: { (result: Result<Int, Error>) in
            delivered.append((try? result.get()) ?? -1)
            lastDelivered.fulfill()
        }) {
            ran.withLock { $0.append(3) }
            return 3
        }
        stale.forEach { $0.cancel() }
        gate.signal()

        wait(for: [lastDelivered], timeout: 5)
        XCTAssertEqual(ran.withLock { $0 }, [3], "stale reads are skipped, not run and dropped")
        XCTAssertEqual(delivered, [3])
        current.cancel()
    }

    // MARK: - Launch

    func test_launch_adapter_maps_resume_source_from_summary() throws {
        let host = LauncherFakeHost(windowID: WindowID("win-adapter"), store: makeStore())
        let liveIndex = LiveAgentSessionIndex(
            sources: { [] },
            preferredWindowID: { host.windowID },
            isProcessAlive: { _ in true }
        )
        var fileSystem = FakeHistoryFileSystem()
        fileSystem.makeDirectory(projectPath)
        let recorder = LauncherFakeUsageRecorder()
        let launcher = AgentHistoryLauncher(
            hosts: { [host] },
            presentingHost: { host },
            liveIndex: liveIndex,
            usageRecorder: recorder,
            fileSystem: fileSystem
        )
        let adapter = AgentHistoryLaunchAdapter(launcher: launcher, liveIndex: liveIndex)
        let summary = AgentHistorySessionSummary(
            id: 42, sourceID: 1, sourceRoot: "", agent: .claude,
            nativeID: sessionID, title: "Fix the parser", titleKind: .generated,
            cwd: projectPath, createdAtMs: 1_000, updatedAtMs: 2_000, turnCount: 4
        )
        let source = AgentHistoryResumeSource(summary: summary)

        XCTAssertEqual(source.sessionRowID, 42)
        XCTAssertEqual(source.key, AgentHistorySessionKey(agent: .claude, nativeID: sessionID))
        XCTAssertEqual(source.workingDirectory, projectPath)
        XCTAssertNil(source.sourceRoot, "an empty source root means the default root")
        XCTAssertEqual(adapter.resumePlan(for: source), AgentHistoryResumeCommandBuilder.availability(for: source))
        guard case .available(let plan) = adapter.resumePlan(for: source) else {
            return XCTFail("expected a resume command for a Claude session")
        }

        let outcome = adapter.launch(source, intent: .primary, folderChoice: nil)

        guard case .resumed(let launched) = outcome else {
            return XCTFail("expected a resume, got \(outcome)")
        }
        let pane = try XCTUnwrap(
            host.worklaneStore.worklanes.flatMap(\.paneStripState.panes).first { $0.id == launched.paneID }
        )
        XCTAssertEqual(pane.sessionRequest.command, plan.command)
        XCTAssertEqual(pane.sessionRequest.workingDirectory, projectPath)
        XCTAssertEqual(host.toasts, ["Resuming Fix the parser"])
        XCTAssertEqual(recorder.opens.map(\.rowID), [42])

        let copy = adapter.launch(source, intent: .primary, folderChoice: .copyResumeCommand)
        XCTAssertEqual(copy, .failed(message: AgentHistoryLauncher.copyCommandMessage, offerCopySessionID: false))
    }

    // MARK: - Excluded folders

    func test_save_excluded_folders_persists_to_config_file() throws {
        let fileURL = AppConfigStore.temporaryFileURL(prefix: "ZenttyLogicTests.AgentHistoryAdapter.Exclusions")
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = AppConfigStore(fileURL: fileURL)

        try AgentHistoryPaletteServicesAdapter.saveExcludedFolders(["/work/secret"], to: store)

        XCTAssertEqual(store.current.agentHistory.excludedFolders, ["/work/secret"])
        XCTAssertTrue(try String(contentsOf: fileURL, encoding: .utf8).contains("/work/secret"))
    }

    func test_save_excluded_folders_fails_when_config_is_write_protected() throws {
        let fileURL = AppConfigStore.temporaryFileURL(prefix: "ZenttyLogicTests.AgentHistoryAdapter.Protected")
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try "[agent_history\nexcluded_folders = [".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = AppConfigStore(fileURL: fileURL)
        XCTAssertTrue(store.isWriteProtected)

        XCTAssertThrowsError(try AgentHistoryPaletteServicesAdapter.saveExcludedFolders(["/work/secret"], to: store)) {
            XCTAssertEqual($0 as? AgentHistoryExcludedFoldersSaveError, .notSaved)
        }
        XCTAssertEqual(store.current.agentHistory.excludedFolders, [], "nothing applied in memory either")
    }

    /// The file breaks after the store last read it: the save only reached memory, so it is
    /// taken back (an un-excluded folder must not be indexed on a list the file doesn't hold).
    func test_save_excluded_folders_takes_back_the_change_when_the_file_broke_meanwhile() throws {
        let fileURL = AppConfigStore.temporaryFileURL(prefix: "ZenttyLogicTests.AgentHistoryAdapter.BrokeMeanwhile")
        addTeardownBlock { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let store = AppConfigStore(fileURL: fileURL)
        try AgentHistoryPaletteServicesAdapter.saveExcludedFolders(["/work/secret"], to: store)
        try "[agent_history\nexcluded_folders = [".write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try AgentHistoryPaletteServicesAdapter.saveExcludedFolders([], to: store))

        XCTAssertTrue(store.isWriteProtected)
        XCTAssertEqual(store.current.agentHistory.excludedFolders, ["/work/secret"])
    }

    func test_save_excluded_folders_fails_without_config_store() {
        XCTAssertThrowsError(try AgentHistoryPaletteServicesAdapter.saveExcludedFolders(["/work/secret"], to: nil))
    }

    // MARK: - Fixtures

    private func makeStore() -> WorklaneStore {
        let windowID = WindowID("win-adapter")
        let worklaneID = WorklaneID("wl-adapter")
        let paneID = PaneID("pn-adapter")
        let store = WorklaneStore(
            windowID: windowID,
            worklanes: [
                WorklaneState(
                    id: worklaneID,
                    title: nil,
                    paneStripState: PaneStripState(
                        panes: [
                            PaneState(
                                id: paneID,
                                title: "zsh",
                                sessionRequest: TerminalSessionRequest(workingDirectory: projectPath),
                                width: 420
                            ),
                        ],
                        focusedPaneID: paneID
                    ),
                    nextPaneNumber: 2
                ),
            ],
            activeWorklaneID: worklaneID,
            gitContextResolver: LauncherTestGitResolver()
        )
        store.knownNonRepositoryPaths.insert(projectPath)
        return store
    }
}
