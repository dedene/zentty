import XCTest
@testable import Zentty

@MainActor
final class SidebarMotionCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var widthDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SidebarMotionCoordinatorTests.visibility")!
        defaults.removePersistentDomain(forName: "SidebarMotionCoordinatorTests.visibility")
        widthDefaults = UserDefaults(suiteName: "SidebarMotionCoordinatorTests.width")!
        widthDefaults.removePersistentDomain(forName: "SidebarMotionCoordinatorTests.width")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "SidebarMotionCoordinatorTests.visibility")
        widthDefaults.removePersistentDomain(forName: "SidebarMotionCoordinatorTests.width")
        super.tearDown()
    }

    // MARK: - Initial state

    func test_initial_mode_is_pinned_open_by_default() {
        let coordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: defaults,
            sidebarWidthDefaults: widthDefaults
        )

        XCTAssertEqual(coordinator.mode, .pinnedOpen)
    }

    func test_initial_mode_restores_persisted_hidden() {
        SidebarVisibilityPreference.persist(.hidden, in: defaults)

        let coordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: defaults,
            sidebarWidthDefaults: widthDefaults
        )

        XCTAssertEqual(coordinator.mode, .hidden)
    }

    // MARK: - Toggle events

    func test_toggle_from_pinned_transitions_to_hidden() {
        let coordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: defaults,
            sidebarWidthDefaults: widthDefaults
        )
        var notifiedStates: [(SidebarMotionState, Bool)] = []
        coordinator.onMotionStateDidChange = { state, animated in
            notifiedStates.append((state, animated))
        }

        coordinator.handle(.togglePressed)

        XCTAssertEqual(coordinator.mode, .hidden)
        XCTAssertEqual(notifiedStates.count, 1)
        XCTAssertEqual(notifiedStates.first?.0, .hidden)
        XCTAssertEqual(notifiedStates.first?.1, true)
    }

    func test_toggle_from_hidden_transitions_to_pinned_open() {
        SidebarVisibilityPreference.persist(.hidden, in: defaults)
        let coordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: defaults,
            sidebarWidthDefaults: widthDefaults
        )
        var notifiedStates: [(SidebarMotionState, Bool)] = []
        coordinator.onMotionStateDidChange = { state, animated in
            notifiedStates.append((state, animated))
        }

        coordinator.handle(.togglePressed)

        XCTAssertEqual(coordinator.mode, .pinnedOpen)
        XCTAssertEqual(notifiedStates.count, 1)
        XCTAssertEqual(notifiedStates.first?.0, .pinnedOpen)
    }

    // MARK: - Hover peek

    func test_hover_rail_entered_from_hidden_enters_hover_peek() {
        SidebarVisibilityPreference.persist(.hidden, in: defaults)
        let coordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: defaults,
            sidebarWidthDefaults: widthDefaults
        )

        coordinator.handle(.hoverRailEntered)

        XCTAssertEqual(coordinator.mode, .hoverPeek)
        XCTAssertTrue(coordinator.isFloating)
    }

    func test_hover_rail_entered_from_pinned_stays_pinned() {
        let coordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: defaults,
            sidebarWidthDefaults: widthDefaults
        )
        var notifiedStates: [(SidebarMotionState, Bool)] = []
        coordinator.onMotionStateDidChange = { state, animated in
            notifiedStates.append((state, animated))
        }

        coordinator.handle(.hoverRailEntered)

        XCTAssertEqual(coordinator.mode, .pinnedOpen)
        XCTAssertTrue(notifiedStates.isEmpty)
    }

    // MARK: - Persistence

    func test_toggle_persists_mode() {
        let coordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: defaults,
            sidebarWidthDefaults: widthDefaults
        )

        coordinator.handle(.togglePressed)

        XCTAssertEqual(
            SidebarVisibilityPreference.restoredVisibility(from: defaults),
            .hidden
        )
    }

    // MARK: - Sidebar width

    func test_setSidebarWidth_clamps_and_updates() {
        let coordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: defaults,
            sidebarWidthDefaults: widthDefaults
        )

        coordinator.setSidebarWidth(9999, availableWidth: 900, persist: true)

        XCTAssertEqual(
            coordinator.currentSidebarWidth,
            SidebarWidthPreference.maximumWidth(for: 900)
        )
    }

    func test_setSidebarWidth_persists_when_requested() {
        let coordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: defaults,
            sidebarWidthDefaults: widthDefaults
        )

        coordinator.setSidebarWidth(250, persist: true)

        XCTAssertEqual(
            SidebarWidthPreference.restoredWidth(from: widthDefaults),
            250
        )
    }

    func test_setSidebarWidth_persists_screen_aware_clamp_when_requested() {
        let coordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: defaults,
            sidebarWidthDefaults: widthDefaults
        )

        coordinator.setSidebarWidth(9999, availableWidth: 900, persist: true)

        XCTAssertEqual(
            SidebarWidthPreference.restoredWidth(from: widthDefaults, availableWidth: 900),
            SidebarWidthPreference.maximumWidth(for: 900)
        )
    }

    func test_setSidebarWidth_does_not_persist_when_not_requested() {
        let coordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: defaults,
            sidebarWidthDefaults: widthDefaults
        )

        coordinator.setSidebarWidth(250, persist: false)

        XCTAssertEqual(coordinator.currentSidebarWidth, 250)
        XCTAssertEqual(
            SidebarWidthPreference.restoredWidth(from: widthDefaults),
            SidebarWidthPreference.defaultWidth
        )
    }

    // MARK: - Effective leading inset

    func test_effectiveLeadingInset_is_zero_when_hidden() {
        SidebarVisibilityPreference.persist(.hidden, in: defaults)
        let coordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: defaults,
            sidebarWidthDefaults: widthDefaults
        )

        XCTAssertEqual(coordinator.effectiveLeadingInset(sidebarWidth: 280), 0)
    }

    func test_effectiveLeadingInset_includes_gap_when_pinned() {
        let coordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: defaults,
            sidebarWidthDefaults: widthDefaults
        )
        let expected = SidebarWidthPreference.clamped(280) + ShellMetrics.shellGap

        XCTAssertEqual(coordinator.effectiveLeadingInset(sidebarWidth: 280), expected)
    }

    // MARK: - Properties forwarding

    func test_showsResizeHandle_true_when_pinned() {
        let coordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: defaults,
            sidebarWidthDefaults: widthDefaults
        )

        XCTAssertTrue(coordinator.showsResizeHandle)
    }

    func test_showsResizeHandle_false_when_hidden() {
        SidebarVisibilityPreference.persist(.hidden, in: defaults)
        let coordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: defaults,
            sidebarWidthDefaults: widthDefaults
        )

        XCTAssertFalse(coordinator.showsResizeHandle)
    }

    // MARK: - No-op when mode unchanged

    func test_no_notification_when_mode_unchanged() {
        let coordinator = SidebarMotionCoordinator(
            sidebarVisibilityDefaults: defaults,
            sidebarWidthDefaults: widthDefaults
        )
        var callCount = 0
        coordinator.onMotionStateDidChange = { _, _ in
            callCount += 1
        }

        coordinator.handle(.sidebarEntered)
        coordinator.handle(.sidebarExited)

        XCTAssertEqual(callCount, 0)
    }
}
