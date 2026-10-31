import XCTest
@testable import Zentty

@MainActor
final class WorklaneStoreLaunchTests: XCTestCase {
    private let worklaneA = WorklaneID("lane-a")
    private let worklaneB = WorklaneID("lane-b")
    private let paneA = PaneID("pane-a")
    private let paneB = PaneID("pane-b")

    // MARK: - openWorklane

    func test_openWorklane_inserts_selects_and_returns_lane_with_single_pane() throws {
        let store = makeStore()

        let launched = store.openWorklane(
            workingDirectory: "/tmp/resume-project",
            command: "claude --resume abc"
        )

        XCTAssertEqual(store.worklanes.count, 3)
        XCTAssertEqual(store.activeWorklaneID, launched.worklaneID)
        let lane = try XCTUnwrap(store.worklanes.first { $0.id == launched.worklaneID })
        XCTAssertEqual(lane.paneStripState.panes.count, 1)
        let pane = try XCTUnwrap(lane.paneStripState.panes.first)
        XCTAssertEqual(pane.id, launched.paneID)
        XCTAssertEqual(pane.sessionRequest.command, "claude --resume abc")
        XCTAssertEqual(pane.sessionRequest.workingDirectory, "/tmp/resume-project")
        XCTAssertEqual(pane.sessionRequest.surfaceContext, .tab)
        XCTAssertFalse(pane.sessionRequest.replaysCommandOnRestore)
        XCTAssertEqual(lane.paneStripState.focusedPaneID, launched.paneID)
    }

    func test_openWorklane_uses_insertion_index_after_anchor() {
        let store = makeStore(activeWorklaneID: worklaneB)

        let launched = store.openWorklane(
            PaneLaunchRequest(workingDirectory: "/tmp/p", command: nil),
            anchorWorklaneID: worklaneA
        )

        XCTAssertEqual(store.worklanes.map(\.id), [worklaneA, launched.worklaneID, worklaneB])
    }

    func test_openWorklane_without_anchor_inserts_after_active_lane() {
        let store = makeStore(activeWorklaneID: worklaneA)

        let launched = store.openWorklane(PaneLaunchRequest(workingDirectory: "/tmp/p", command: nil))

        XCTAssertEqual(store.worklanes.map(\.id), [worklaneA, launched.worklaneID, worklaneB])
    }

    func test_openWorklane_sets_title_when_given_and_nil_otherwise() {
        let store = makeStore()

        let titled = store.openWorklane(
            PaneLaunchRequest(workingDirectory: "/tmp/p", command: nil, title: "  Resumed work  ")
        )
        let untitled = store.openWorklane(PaneLaunchRequest(workingDirectory: "/tmp/p", command: nil))

        XCTAssertEqual(store.worklanes.first { $0.id == titled.worklaneID }?.title, "Resumed work")
        XCTAssertNil(store.worklanes.first { $0.id == untitled.worklaneID }?.title)
    }

    func test_openWorklane_merges_sanitized_environment_and_drops_reserved_keys() throws {
        let store = makeStore()

        let launched = store.openWorklane(
            workingDirectory: "/tmp/p",
            command: "codex resume x",
            environment: [
                "CLAUDE_CONFIG_DIR": "/tmp/alt-claude",
                "_UNDERSCORE_OK": "1",
                "PATH": "/evil/bin",
                "TMUX": "/evil/socket",
                "TMUX_PANE": "%99",
                "ZENTTY_PANE_ID": "spoofed",
                "ZENTTY_ANYTHING": "spoofed",
                "1BAD": "x",
                "BAD-KEY": "x",
                "": "x",
                "WITH SPACE": "x",
            ]
        )

        let pane = try XCTUnwrap(
            store.worklanes.first { $0.id == launched.worklaneID }?.paneStripState.panes.first
        )
        let env = pane.sessionRequest.environmentVariables
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/tmp/alt-claude")
        XCTAssertEqual(env["_UNDERSCORE_OK"], "1")
        XCTAssertNotEqual(env["PATH"], "/evil/bin")
        XCTAssertNotEqual(env["TMUX"], "/evil/socket")
        XCTAssertNotEqual(env["TMUX_PANE"], "%99")
        XCTAssertEqual(env["ZENTTY_PANE_ID"], launched.paneID.rawValue)
        XCTAssertEqual(env["ZENTTY_WORKLANE_ID"], launched.worklaneID.rawValue)
        XCTAssertNil(env["ZENTTY_ANYTHING"])
        XCTAssertNil(env["1BAD"])
        XCTAssertNil(env["BAD-KEY"])
        XCTAssertNil(env[""])
        XCTAssertNil(env["WITH SPACE"])
    }

    func test_sanitizedLaunchEnvironment_keeps_only_valid_unreserved_names() {
        let sanitized = WorklaneStore.sanitizedLaunchEnvironment([
            "OK_NAME": "a",
            "lower_ok2": "b",
            "PATH": "c",
            "TMUX": "d",
            "TMUX_PANE": "e",
            "ZENTTY_X": "f",
            "9LIVES": "g",
            "É": "h",
            "A=B": "i",
        ])

        XCTAssertEqual(sanitized, ["OK_NAME": "a", "lower_ok2": "b"])
    }

    func test_openWorklane_notifies_worklaneListChanged_then_activeWorklaneChanged() {
        let store = makeStore()
        var changes: [WorklaneChange] = []
        store.subscribe { changes.append($0) }

        store.openWorklane(PaneLaunchRequest(workingDirectory: "/tmp/p", command: nil))

        let listIndex = changes.firstIndex(of: .worklaneListChanged)
        let activeIndex = changes.firstIndex(of: .activeWorklaneChanged)
        XCTAssertNotNil(listIndex)
        XCTAssertNotNil(activeIndex)
        if let listIndex, let activeIndex {
            XCTAssertLessThan(listIndex, activeIndex)
        }
    }

    // MARK: - openSplit

    func test_openSplit_inserts_column_right_of_target_with_command_and_no_replay() throws {
        let store = makeStore()

        let launched = try XCTUnwrap(
            store.openSplit(
                in: worklaneA,
                targetPaneID: paneA,
                PaneLaunchRequest(
                    workingDirectory: "/tmp/split-project",
                    command: "grok --resume s1",
                    environment: ["CLAUDE_CONFIG_DIR": "/tmp/alt", "ZENTTY_PANE_ID": "spoofed"]
                )
            )
        )

        XCTAssertEqual(launched.worklaneID, worklaneA)
        let columns = try XCTUnwrap(store.worklanes.first { $0.id == worklaneA }?.paneStripState.columns)
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns[0].panes.map(\.id), [paneA])
        let pane = try XCTUnwrap(columns[1].panes.first)
        XCTAssertEqual(pane.id, launched.paneID)
        XCTAssertEqual(pane.sessionRequest.command, "grok --resume s1")
        XCTAssertEqual(pane.sessionRequest.workingDirectory, "/tmp/split-project")
        XCTAssertFalse(pane.sessionRequest.replaysCommandOnRestore)
        XCTAssertEqual(pane.sessionRequest.environmentVariables["CLAUDE_CONFIG_DIR"], "/tmp/alt")
        XCTAssertNotEqual(pane.sessionRequest.environmentVariables["ZENTTY_PANE_ID"], "spoofed")
    }

    func test_openSplit_returns_nil_for_unknown_worklane_or_pane() {
        let store = makeStore()
        let request = PaneLaunchRequest(workingDirectory: "/tmp/p", command: "claude")

        XCTAssertNil(store.openSplit(in: WorklaneID("missing"), targetPaneID: paneA, request))
        XCTAssertNil(store.openSplit(in: worklaneA, targetPaneID: PaneID("missing"), request))
        XCTAssertEqual(store.worklanes.first { $0.id == worklaneA }?.paneStripState.panes.count, 1)
    }

    // MARK: - Helpers

    private func makeStore(activeWorklaneID: WorklaneID? = nil) -> WorklaneStore {
        let store = WorklaneStore(
            worklanes: [
                makeWorklane(id: worklaneA, paneID: paneA),
                makeWorklane(id: worklaneB, paneID: paneB),
            ],
            activeWorklaneID: activeWorklaneID ?? worklaneA
        )
        store.knownNonRepositoryPaths.formUnion(["/tmp/project", "/tmp/p", "/tmp/resume-project", "/tmp/split-project"])
        return store
    }

    private func makeWorklane(id: WorklaneID, paneID: PaneID) -> WorklaneState {
        WorklaneState(
            id: id,
            title: nil,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(
                        id: paneID,
                        title: "shell",
                        sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp/project"),
                        width: 420
                    ),
                ],
                focusedPaneID: paneID
            ),
            nextPaneNumber: 2,
            auxiliaryStateByPaneID: [
                paneID: PaneAuxiliaryState(
                    shellContext: PaneShellContext(
                        scope: .local,
                        path: "/tmp/project",
                        home: "/Users/peter",
                        user: "peter",
                        host: nil
                    )
                ),
            ]
        )
    }
}
