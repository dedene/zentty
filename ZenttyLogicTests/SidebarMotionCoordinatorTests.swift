import XCTest
@testable import Zentty

private func makeSidebarMotionCoordinatorTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ZenttyTests.SidebarMotionCoordinator.\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeSidebarMotionCoordinatorTestDefaults(suffix: String) -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "ZenttyTests.SidebarMotionCoordinatorTests.\(suffix).\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName) ?? .standard, suiteName)
}

@MainActor
final class SidebarMotionCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        sidebarVisibility: SidebarVisibilityMode? = nil,
        sidebarWidth: CGFloat? = nil
    ) throws -> (coordinator: SidebarMotionCoordinator, store: AppConfigStore) {
        let temporaryDirectoryURL = try makeSidebarMotionCoordinatorTestDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }

        let (sidebarWidthDefaults, widthSuiteName) = makeSidebarMotionCoordinatorTestDefaults(suffix: "width")
        let (sidebarVisibilityDefaults, visibilitySuiteName) = makeSidebarMotionCoordinatorTestDefaults(suffix: "visibility")
        addTeardownBlock {
            UserDefaults(suiteName: widthSuiteName)?.removePersistentDomain(forName: widthSuiteName)
            UserDefaults(suiteName: visibilitySuiteName)?.removePersistentDomain(forName: visibilitySuiteName)
        }

        if let sidebarVisibility {
            SidebarVisibilityPreference.persist(sidebarVisibility, in: sidebarVisibilityDefaults)
        }
        if let sidebarWidth {
            SidebarWidthPreference.persist(sidebarWidth, in: sidebarWidthDefaults)
        }

        let store = AppConfigStore(
            fileURL: temporaryDirectoryURL.appendingPathComponent("config.toml"),
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: .standard
        )
        return (SidebarMotionCoordinator(configStore: store), store)
    }

    // MARK: - Initial state

    func test_initial_mode_is_pinned_open_by_default() throws {
        let (coordinator, _) = try makeCoordinator()

        XCTAssertEqual(coordinator.mode, .pinnedOpen)
    }

    func test_initial_mode_restores_persisted_hidden() throws {
        let (coordinator, _) = try makeCoordinator(sidebarVisibility: .hidden)

        XCTAssertEqual(coordinator.mode, .hidden)
    }

    // MARK: - Toggle events

    func test_toggle_from_pinned_transitions_to_hidden() throws {
        let (coordinator, _) = try makeCoordinator()
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

    func test_toggle_from_hidden_transitions_to_pinned_open() throws {
        let (coordinator, _) = try makeCoordinator(sidebarVisibility: .hidden)
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

    func test_hover_rail_entered_from_hidden_enters_hover_peek() throws {
        let (coordinator, _) = try makeCoordinator(sidebarVisibility: .hidden)

        coordinator.handle(.hoverRailEntered)

        XCTAssertEqual(coordinator.mode, .hoverPeek)
        XCTAssertTrue(coordinator.isFloating)
    }

    func test_hover_rail_entered_from_pinned_stays_pinned() throws {
        let (coordinator, _) = try makeCoordinator()
        var notifiedStates: [(SidebarMotionState, Bool)] = []
        coordinator.onMotionStateDidChange = { state, animated in
            notifiedStates.append((state, animated))
        }

        coordinator.handle(.hoverRailEntered)

        XCTAssertEqual(coordinator.mode, .pinnedOpen)
        XCTAssertTrue(notifiedStates.isEmpty)
    }

    // MARK: - Persistence

    func test_toggle_persists_mode() throws {
        let (coordinator, store) = try makeCoordinator()

        coordinator.handle(.togglePressed)

        XCTAssertEqual(store.current.sidebar.visibility, .hidden)
    }

    // MARK: - Sidebar width

    func test_setSidebarWidth_clamps_and_updates() throws {
        let (coordinator, _) = try makeCoordinator()

        coordinator.setSidebarWidth(9999, availableWidth: 900, persist: true)

        XCTAssertEqual(
            coordinator.currentSidebarWidth,
            SidebarWidthPreference.maximumWidth(for: 900)
        )
    }

    func test_setSidebarWidth_persists_when_requested() throws {
        let (coordinator, store) = try makeCoordinator()

        coordinator.setSidebarWidth(250, persist: true)

        XCTAssertEqual(store.current.sidebar.width, 250)
    }

    func test_setSidebarWidth_persists_screen_aware_clamp_when_requested() throws {
        let (coordinator, store) = try makeCoordinator()

        coordinator.setSidebarWidth(9999, availableWidth: 900, persist: true)

        XCTAssertEqual(store.current.sidebar.width, SidebarWidthPreference.maximumWidth(for: 900))
    }

    func test_setSidebarWidth_does_not_persist_when_not_requested() throws {
        let (coordinator, store) = try makeCoordinator()

        coordinator.setSidebarWidth(250, persist: false)

        XCTAssertEqual(coordinator.currentSidebarWidth, 250)
        XCTAssertEqual(store.current.sidebar.width, SidebarWidthPreference.defaultWidth)
    }

    // MARK: - Effective leading inset

    func test_effectiveLeadingInset_is_zero_when_hidden() throws {
        let (coordinator, _) = try makeCoordinator(sidebarVisibility: .hidden)

        XCTAssertEqual(coordinator.effectiveLeadingInset(sidebarWidth: 280), 0)
    }

    func test_effectiveLeadingInset_includes_gap_when_pinned() throws {
        let (coordinator, _) = try makeCoordinator()
        let expected = SidebarWidthPreference.clamped(280) + ShellMetrics.shellGap

        XCTAssertEqual(coordinator.effectiveLeadingInset(sidebarWidth: 280), expected)
    }

    // MARK: - Properties forwarding

    func test_showsResizeHandle_true_when_pinned() throws {
        let (coordinator, _) = try makeCoordinator()

        XCTAssertTrue(coordinator.showsResizeHandle)
    }

    func test_showsResizeHandle_false_when_hidden() throws {
        let (coordinator, _) = try makeCoordinator(sidebarVisibility: .hidden)

        XCTAssertFalse(coordinator.showsResizeHandle)
    }

    // MARK: - No-op when mode unchanged

    func test_no_notification_when_mode_unchanged() throws {
        let (coordinator, _) = try makeCoordinator()
        var callCount = 0
        coordinator.onMotionStateDidChange = { _, _ in
            callCount += 1
        }

        coordinator.handle(.sidebarEntered)
        coordinator.handle(.sidebarExited)

        XCTAssertEqual(callCount, 0)
    }
}
