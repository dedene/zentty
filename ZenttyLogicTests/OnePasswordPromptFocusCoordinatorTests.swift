import XCTest
@testable import Zentty

@MainActor
final class OnePasswordPromptFocusCoordinatorTests: XCTestCase {
    private var revealed: [OnePasswordPromptCandidate] = []
    private var restored: [OnePasswordPromptFocusLocation] = []
    private var focusedPaneID: PaneID?
    private var returnEnabled = true
    private var alivePIDs: Set<Int32> = []
    private var enabled = true
    private var onePasswordRunning = true
    private var heldScans: [@Sendable () -> Void] = []
    private var clock = Date(timeIntervalSince1970: 1_000)

    private let origin = OnePasswordPromptFocusLocation(windowID: WindowID("w"), worklaneID: WorklaneID("l"), paneID: PaneID("origin"))
    private let prompt = OnePasswordPromptWindow(id: 9, ownerName: "1Password")
    private let touchID = OnePasswordPromptWindow(id: 8, ownerName: "UserNotificationCenter")

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

    // MARK: - Jump back

    func test_returns_to_origin_after_prompt_window_closes_and_grace_passes() async {
        focusedPaneID = origin.paneID
        let coordinator = makeCoordinator(opPIDs: [100: 101])
        await triggerPrompt(coordinator)
        XCTAssertEqual(revealed.count, 1)
        focusedPaneID = PaneID("a")

        coordinator.handleWindowSnapshot(baseline)
        XCTAssertTrue(restored.isEmpty, "Must wait for the grace period")
        clock = clock.addingTimeInterval(1)
        coordinator.handleWindowSnapshot(baseline)
        XCTAssertTrue(restored.isEmpty)
        clock = clock.addingTimeInterval(1)
        coordinator.handleWindowSnapshot(baseline)

        XCTAssertEqual(restored, [origin])
        coordinator.handleWindowSnapshot(baseline)
        XCTAssertEqual(restored.count, 1, "Returns once")
    }

    func test_does_not_return_while_prompt_window_is_still_on_screen() async {
        focusedPaneID = origin.paneID
        let coordinator = makeCoordinator(opPIDs: [100: 101])
        await triggerPrompt(coordinator)
        focusedPaneID = PaneID("a")

        clock = clock.addingTimeInterval(30)
        coordinator.handleWindowSnapshot(baseline + [prompt])

        XCTAssertTrue(restored.isEmpty)
    }

    func test_touch_id_handoff_to_approval_panel_does_not_bounce() async {
        focusedPaneID = origin.paneID
        let coordinator = makeCoordinator(opPIDs: [100: 101])
        coordinator.handleWindowSnapshot(baseline)
        coordinator.handleWindowSnapshot(baseline + [touchID])
        await Task.yield()
        XCTAssertEqual(revealed.count, 1)
        focusedPaneID = PaneID("a")

        // Touch ID sheet goes away, approval panel arrives a moment later.
        clock = clock.addingTimeInterval(0.5)
        coordinator.handleWindowSnapshot(baseline)
        clock = clock.addingTimeInterval(0.5)
        coordinator.handleWindowSnapshot(baseline + [prompt])
        await Task.yield()
        clock = clock.addingTimeInterval(5)
        coordinator.handleWindowSnapshot(baseline + [prompt])
        XCTAssertTrue(restored.isEmpty, "Approval panel is still up")
        XCTAssertEqual(revealed.count, 1, "The second window belongs to the same request")

        coordinator.handleWindowSnapshot(baseline)
        clock = clock.addingTimeInterval(2)
        coordinator.handleWindowSnapshot(baseline)

        XCTAssertEqual(restored, [origin])
    }

    func test_does_not_return_when_user_moved_to_another_pane() async {
        focusedPaneID = origin.paneID
        let coordinator = makeCoordinator(opPIDs: [100: 101])
        await triggerPrompt(coordinator)
        focusedPaneID = PaneID("somewhere-else")

        coordinator.handleWindowSnapshot(baseline)
        clock = clock.addingTimeInterval(2)
        coordinator.handleWindowSnapshot(baseline)

        XCTAssertTrue(restored.isEmpty)
    }

    func test_waits_for_op_to_exit_then_returns() async {
        focusedPaneID = origin.paneID
        alivePIDs = [101]
        let coordinator = makeCoordinator(opPIDs: [100: 101])
        await triggerPrompt(coordinator)
        focusedPaneID = PaneID("a")

        coordinator.handleWindowSnapshot(baseline)
        clock = clock.addingTimeInterval(2)
        coordinator.handleWindowSnapshot(baseline)
        XCTAssertTrue(restored.isEmpty, "op is still running")

        alivePIDs = []
        clock = clock.addingTimeInterval(0.5)
        coordinator.handleWindowSnapshot(baseline)

        XCTAssertEqual(restored, [origin])
    }

    func test_gives_up_when_op_keeps_running_after_prompt_closed() async {
        focusedPaneID = origin.paneID
        alivePIDs = [101]
        let coordinator = makeCoordinator(opPIDs: [100: 101])
        await triggerPrompt(coordinator)
        focusedPaneID = PaneID("a")

        coordinator.handleWindowSnapshot(baseline)
        clock = clock.addingTimeInterval(6)
        coordinator.handleWindowSnapshot(baseline)
        alivePIDs = []
        clock = clock.addingTimeInterval(1)
        coordinator.handleWindowSnapshot(baseline)

        XCTAssertTrue(restored.isEmpty)
    }

    func test_no_return_when_disabled() async {
        focusedPaneID = origin.paneID
        returnEnabled = false
        let coordinator = makeCoordinator(opPIDs: [100: 101])
        await triggerPrompt(coordinator)
        XCTAssertEqual(revealed.count, 1)
        focusedPaneID = PaneID("a")

        coordinator.handleWindowSnapshot(baseline)
        clock = clock.addingTimeInterval(2)
        coordinator.handleWindowSnapshot(baseline)

        XCTAssertTrue(restored.isEmpty)
    }

    func test_no_return_when_nothing_was_revealed() async {
        focusedPaneID = origin.paneID
        let coordinator = makeCoordinator(opPIDs: [:], sources: [
            OnePasswordPromptPaneSource(windowID: WindowID("w"), worklaneID: WorklaneID("l"), paneID: PaneID("a"), rootPID: 100)
        ])
        await triggerPrompt(coordinator)
        XCTAssertTrue(revealed.isEmpty)

        coordinator.handleWindowSnapshot(baseline)
        clock = clock.addingTimeInterval(2)
        coordinator.handleWindowSnapshot(baseline)

        XCTAssertTrue(restored.isEmpty)
    }

    func test_presence_loss_drops_pending_return() async {
        focusedPaneID = origin.paneID
        let coordinator = makeCoordinator(opPIDs: [100: 101])
        await triggerPrompt(coordinator)
        XCTAssertEqual(revealed.count, 1)
        focusedPaneID = PaneID("a")
        coordinator.handleWindowSnapshot(baseline)

        onePasswordRunning = false
        coordinator.pollForTesting()

        // 1Password came back; no new prompt, and the request pane still has focus.
        onePasswordRunning = true
        clock = clock.addingTimeInterval(10)
        coordinator.handleWindowSnapshot(baseline)
        clock = clock.addingTimeInterval(2)
        coordinator.handleWindowSnapshot(baseline)

        XCTAssertTrue(restored.isEmpty, "A return from before 1Password quit must not fire")
    }

    func test_scan_finishing_after_stop_does_not_reveal() async {
        let coordinator = makeCoordinator(opPIDs: [100: 101], holdScans: true)
        coordinator.handleWindowSnapshot(baseline)
        XCTAssertTrue(coordinator.handleWindowSnapshot(baseline + [prompt]))

        coordinator.stop()
        heldScans.forEach { $0() }
        await Task.yield()

        XCTAssertTrue(revealed.isEmpty)
    }

    func test_scan_finishing_after_disable_does_not_reveal() async {
        let coordinator = makeCoordinator(opPIDs: [100: 101], holdScans: true)
        coordinator.handleWindowSnapshot(baseline)
        XCTAssertTrue(coordinator.handleWindowSnapshot(baseline + [prompt]))

        // The disable lands between polls, so nothing has invalidated the scan yet.
        enabled = false
        heldScans.forEach { $0() }
        await Task.yield()

        XCTAssertTrue(revealed.isEmpty)
    }

    func test_scan_held_across_a_disabled_poll_does_not_reveal_after_reenable() async {
        let coordinator = makeCoordinator(opPIDs: [100: 101], holdScans: true)
        coordinator.handleWindowSnapshot(baseline)
        XCTAssertTrue(coordinator.handleWindowSnapshot(baseline + [prompt]))

        enabled = false
        coordinator.pollForTesting()
        enabled = true
        heldScans.forEach { $0() }
        await Task.yield()

        XCTAssertTrue(revealed.isEmpty)
    }

    private func triggerPrompt(_ coordinator: OnePasswordPromptFocusCoordinator) async {
        coordinator.handleWindowSnapshot(baseline)
        coordinator.handleWindowSnapshot(baseline + [prompt])
        await Task.yield()
    }

    private func makeCoordinator(
        opPIDs: [Int32: Int32],
        sources: [OnePasswordPromptPaneSource]? = nil,
        holdScans: Bool = false
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
                isEnabled: { [unowned self] in enabled },
                isReturnEnabled: { [unowned self] in returnEnabled },
                sources: { sources ?? defaultSources },
                isPaneFocused: { [unowned self] source in source.paneID == focusedPaneID },
                reveal: { [unowned self] in revealed.append($0) },
                currentFocus: { [unowned self] in
                    focusedPaneID.map {
                        OnePasswordPromptFocusLocation(windowID: WindowID("w"), worklaneID: WorklaneID("l"), paneID: $0)
                    }
                },
                restoreFocus: { [unowned self] in restored.append($0) }
            ),
            attributor: OnePasswordPromptAttributor(processProvider: provider),
            snapshotter: StubSnapshotter(),
            isProcessAlive: { [unowned self] pid in alivePIDs.contains(pid) },
            isOnePasswordRunning: { [unowned self] in onePasswordRunning },
            scanExecutor: { [unowned self] work in
                if holdScans {
                    heldScans.append(work)
                } else {
                    work()
                }
            },
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
