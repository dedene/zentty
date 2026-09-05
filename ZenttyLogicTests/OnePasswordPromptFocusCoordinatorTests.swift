import XCTest
@testable import Zentty

@MainActor
final class OnePasswordPromptFocusCoordinatorTests: XCTestCase {
    private var revealed: [OnePasswordPromptCandidate] = []
    private var focusedPaneID: PaneID?
    private var clock = Date(timeIntervalSince1970: 1_000)

    private let baseline = [
        OnePasswordPromptWindow(id: 1, ownerName: "Finder"),
        OnePasswordPromptWindow(id: 2, ownerName: "1Password"),
    ]

    func test_first_snapshot_only_seeds_baseline() {
        let coordinator = makeCoordinator(opPIDs: [100: 101])

        XCTAssertFalse(coordinator.handleWindowSnapshot(baseline))
        XCTAssertFalse(coordinator.handleWindowSnapshot(baseline))
    }

    func test_new_one_password_window_reveals_pane_running_op() async {
        let coordinator = makeCoordinator(opPIDs: [100: 101])
        coordinator.handleWindowSnapshot(baseline)

        XCTAssertTrue(coordinator.handleWindowSnapshot(baseline + [OnePasswordPromptWindow(id: 9, ownerName: "1Password")]))
        await Task.yield()

        XCTAssertEqual(revealed.map(\.source.paneID), [PaneID("a")])
    }

    func test_new_touch_id_host_window_also_triggers_scan() {
        let coordinator = makeCoordinator(opPIDs: [100: 101])
        coordinator.handleWindowSnapshot(baseline)

        XCTAssertTrue(coordinator.handleWindowSnapshot(baseline + [OnePasswordPromptWindow(id: 9, ownerName: "UserNotificationCenter")]))
    }

    func test_new_windows_from_other_apps_are_ignored() async {
        let coordinator = makeCoordinator(opPIDs: [100: 101])
        coordinator.handleWindowSnapshot(baseline)

        XCTAssertFalse(coordinator.handleWindowSnapshot(baseline + [OnePasswordPromptWindow(id: 9, ownerName: "Raycast")]))
        await Task.yield()

        XCTAssertTrue(revealed.isEmpty)
    }

    func test_windows_that_disappear_and_return_count_as_new() {
        let coordinator = makeCoordinator(opPIDs: [100: 101])
        coordinator.handleWindowSnapshot(baseline)
        XCTAssertFalse(coordinator.handleWindowSnapshot([baseline[0]]))
        clock = clock.addingTimeInterval(2)

        XCTAssertTrue(coordinator.handleWindowSnapshot(baseline))
    }

    func test_debounces_rapid_triggers() {
        let coordinator = makeCoordinator(opPIDs: [100: 101])
        coordinator.handleWindowSnapshot(baseline)

        XCTAssertTrue(coordinator.handleWindowSnapshot(baseline + [OnePasswordPromptWindow(id: 9, ownerName: "1Password")]))
        clock = clock.addingTimeInterval(0.2)
        XCTAssertFalse(coordinator.handleWindowSnapshot(baseline + [OnePasswordPromptWindow(id: 10, ownerName: "1Password")]))
        clock = clock.addingTimeInterval(2)
        XCTAssertTrue(coordinator.handleWindowSnapshot(baseline + [OnePasswordPromptWindow(id: 11, ownerName: "1Password")]))
    }

    func test_skips_reveal_when_request_pane_is_already_focused() async {
        focusedPaneID = PaneID("a")
        let coordinator = makeCoordinator(opPIDs: [100: 101])
        coordinator.handleWindowSnapshot(baseline)

        coordinator.handleWindowSnapshot(baseline + [OnePasswordPromptWindow(id: 9, ownerName: "1Password")])
        await Task.yield()

        XCTAssertTrue(revealed.isEmpty)
    }

    func test_no_reveal_when_no_pane_holds_a_request() async {
        let coordinator = makeCoordinator(opPIDs: [:], sources: [
            OnePasswordPromptPaneSource(windowID: WindowID("w"), worklaneID: WorklaneID("l"), paneID: PaneID("a"), rootPID: 100)
        ])
        coordinator.handleWindowSnapshot(baseline)

        XCTAssertTrue(coordinator.handleWindowSnapshot(baseline + [OnePasswordPromptWindow(id: 9, ownerName: "1Password")]))
        await Task.yield()

        XCTAssertTrue(revealed.isEmpty)
    }

    func test_does_not_scan_when_no_pane_has_a_root_pid() {
        let coordinator = makeCoordinator(opPIDs: [:], sources: [
            OnePasswordPromptPaneSource(windowID: WindowID("w"), worklaneID: WorklaneID("l"), paneID: PaneID("a"), rootPID: nil)
        ])
        coordinator.handleWindowSnapshot(baseline)

        XCTAssertFalse(coordinator.handleWindowSnapshot(baseline + [OnePasswordPromptWindow(id: 9, ownerName: "1Password")]))
    }

    private func makeCoordinator(
        opPIDs: [Int32: Int32],
        sources: [OnePasswordPromptPaneSource]? = nil
    ) -> OnePasswordPromptFocusCoordinator {
        let provider = StubProvider(opPIDs: opPIDs)
        let defaultSources = opPIDs.keys.sorted().enumerated().map { index, rootPID in
            OnePasswordPromptPaneSource(
                windowID: WindowID("w"),
                worklaneID: WorklaneID("l"),
                paneID: PaneID(String(UnicodeScalar(UInt8(97 + index)))),
                rootPID: rootPID
            )
        }
        return OnePasswordPromptFocusCoordinator(
            hooks: .init(
                isEnabled: { true },
                sources: { sources ?? defaultSources },
                isPaneFocused: { [unowned self] source in source.paneID == focusedPaneID },
                reveal: { [unowned self] in revealed.append($0) }
            ),
            attributor: OnePasswordPromptAttributor(processProvider: provider),
            snapshotter: StubSnapshotter(),
            scanExecutor: { $0() },
            now: { [unowned self] in clock }
        )
    }
}

private struct StubSnapshotter: OnePasswordPromptWindowSnapshotting {
    func onScreenWindows() -> [OnePasswordPromptWindow] { [] }
}

private struct StubProvider: OnePasswordPromptProcessProviding {
    /// root pid -> pid of an `op` child
    let opPIDs: [Int32: Int32]

    func treePIDs(rootPID: Int32) -> [Int32] { [rootPID] + (opPIDs[rootPID].map { [$0] } ?? []) }
    func processName(pid: Int32) -> String? { opPIDs.values.contains(pid) ? "op" : "zsh" }
    func argv(pid: Int32) -> [String]? { ["op", "read"] }
    func startTime(pid: Int32) -> TimeInterval? { TimeInterval(pid) }
    func unixSocketPeerPaths(pid: Int32) -> [String] { [] }
}
