import AppKit
import XCTest
@testable import Zentty

/// Detached preview host, injected dwell scheduler and haptics.
@MainActor
final class FloatDockCoordinatorTests: AppKitTestCase {
    private let floatID = PaneID("float")
    private var columns: [ColumnPresentation] = []
    private var pendingDwell: FloatDockCoordinator.DwellAction?
    private var cancelledDwells = 0
    private let haptics = HapticSpy()
    /// The coordinator holds its preview host weakly (the float layer owns it).
    private var previewHost: NSView?

    override func setUp() {
        super.setUp()
        FloatMotion.reduceMotionOverride = true
        // [A 0–400][B 408–808], full height.
        columns = [Self.column("a", x: 0), Self.column("b", x: 408)]
        pendingDwell = nil
        cancelledDwells = 0
    }

    override func tearDown() {
        previewHost = nil
        FloatMotion.reduceMotionOverride = nil
        super.tearDown()
    }

    func test_enter_shows_dock_here_label() {
        let (coordinator, host) = makeCoordinator()

        coordinator.enter(paneID: floatID, cursor: CGPoint(x: 404, y: 400))

        XCTAssertTrue(coordinator.isActive)
        XCTAssertEqual(coordinator.currentTarget, .columnGap(index: 1))
        XCTAssertEqual(coordinator.previewForTesting.labelText, "Dock here")
        XCTAssertEqual(coordinator.previewForTesting.geometry, .columnLine(CGRect(x: 401, y: 0, width: 6, height: 800)))
        let label = coordinator.labelViewForTesting
        XCTAssertTrue(label?.superview === host)
        XCTAssertEqual(label.map { $0.frame.midX } ?? 0, 404, accuracy: 1, "the label sits on the line")
        XCTAssertTrue(host.subviews.last === label, "the label is above the preview")
        XCTAssertEqual(haptics.events, [.alignment])
    }

    func test_no_target_shows_no_label() {
        let (coordinator, _) = makeCoordinator()

        coordinator.enter(paneID: floatID, cursor: CGPoint(x: 200, y: 400))

        XCTAssertNil(coordinator.currentTarget)
        XCTAssertNil(coordinator.previewForTesting.geometry)
        XCTAssertNil(coordinator.previewForTesting.labelText)
    }

    func test_exit_removes_previews() {
        let (coordinator, host) = makeCoordinator()
        coordinator.enter(paneID: floatID, cursor: CGPoint(x: 404, y: 400))
        XCTAssertFalse(host.subviews.isEmpty)

        coordinator.exit()

        XCTAssertFalse(coordinator.isActive)
        XCTAssertNil(coordinator.currentTarget)
        XCTAssertNil(coordinator.previewForTesting.geometry)
        XCTAssertNil(coordinator.previewForTesting.labelText)
        XCTAssertTrue(host.subviews.isEmpty)
    }

    func test_dwell_promotes_split_preview() throws {
        let (coordinator, _) = makeCoordinator()
        // Near B's top edge.
        coordinator.enter(paneID: floatID, cursor: CGPoint(x: 608, y: 760))
        XCTAssertNil(coordinator.currentTarget, "the split waits for the dwell")
        let dwell = try XCTUnwrap(pendingDwell)

        dwell()

        XCTAssertEqual(coordinator.currentTarget, .split(target: PaneID("b"), axis: .vertical, leading: true))
        XCTAssertEqual(
            coordinator.previewForTesting.geometry,
            .splitHalf(CGRect(x: 408, y: 400, width: 400, height: 400))
        )
        XCTAssertEqual(coordinator.previewForTesting.labelText, "Dock here")
        XCTAssertEqual(haptics.events, [.structural])
    }

    func test_leaving_split_zone_cancels_dwell() {
        let (coordinator, _) = makeCoordinator()
        coordinator.enter(paneID: floatID, cursor: CGPoint(x: 608, y: 760))
        XCTAssertNotNil(pendingDwell)

        coordinator.update(cursor: CGPoint(x: 404, y: 400))

        XCTAssertEqual(cancelledDwells, 1)
        XCTAssertEqual(coordinator.currentTarget, .columnGap(index: 1))
    }

    func test_commit_returns_shown_target_and_tears_down() {
        let (coordinator, host) = makeCoordinator()
        coordinator.enter(paneID: floatID, cursor: CGPoint(x: 404, y: 400))

        XCTAssertEqual(coordinator.commit(cursor: CGPoint(x: 404, y: 400)), .columnGap(index: 1))
        XCTAssertFalse(coordinator.isActive)
        XCTAssertTrue(host.subviews.isEmpty)
    }

    func test_commit_returns_nil_when_target_pane_vanished() throws {
        let (coordinator, _) = makeCoordinator()
        coordinator.enter(paneID: floatID, cursor: CGPoint(x: 608, y: 760))
        try XCTUnwrap(pendingDwell)()
        XCTAssertEqual(coordinator.currentTarget, .split(target: PaneID("b"), axis: .vertical, leading: true))

        // B closes before the release; A grows into its place.
        columns = [Self.column("a", x: 0, width: 808)]

        XCTAssertNil(coordinator.commit(cursor: CGPoint(x: 608, y: 760)), "the float stays where it dropped")
        XCTAssertFalse(coordinator.isActive)
    }

    func test_pointer_outside_the_preview_host_targets_and_commits_nothing() {
        let (coordinator, _) = makeCoordinator()
        coordinator.enter(paneID: floatID, cursor: CGPoint(x: 1250, y: 400))
        XCTAssertNil(coordinator.currentTarget, "past the canvas: not the gap after the last column")
        XCTAssertNil(coordinator.previewForTesting.geometry)

        coordinator.update(cursor: CGPoint(x: 900, y: 400))
        XCTAssertEqual(coordinator.currentTarget, .columnGap(index: 2))

        XCTAssertNil(coordinator.commit(cursor: CGPoint(x: 1250, y: 400)), "released outside the canvas")
    }

    func test_empty_strip_targets_only_inside_the_canvas() {
        columns = []
        let (coordinator, _) = makeCoordinator()
        coordinator.enter(paneID: floatID, cursor: CGPoint(x: -30, y: 400))
        XCTAssertNil(coordinator.currentTarget)

        coordinator.update(cursor: CGPoint(x: 600, y: 400))
        XCTAssertEqual(coordinator.currentTarget, .columnGap(index: 0))

        XCTAssertNil(coordinator.commit(cursor: CGPoint(x: 600, y: 900)), "released below the canvas")
    }

    func test_strip_change_clears_vanished_target_and_keeps_live_one() throws {
        let (coordinator, _) = makeCoordinator()
        coordinator.enter(paneID: floatID, cursor: CGPoint(x: 608, y: 760))
        try XCTUnwrap(pendingDwell)()

        // B's column narrows: the target stays, its preview follows.
        columns = [Self.column("a", x: 0), Self.column("b", x: 408, width: 300)]
        coordinator.stripDidChange()
        XCTAssertEqual(coordinator.currentTarget, .split(target: PaneID("b"), axis: .vertical, leading: true))
        XCTAssertEqual(coordinator.previewForTesting.geometry, .splitHalf(CGRect(x: 408, y: 400, width: 300, height: 400)))

        // B closes: nothing is targeted until the pointer moves.
        columns = [Self.column("a", x: 0, width: 808)]
        coordinator.stripDidChange()
        XCTAssertNil(coordinator.currentTarget)
        XCTAssertNil(coordinator.previewForTesting.labelText)
        XCTAssertNil(coordinator.commit(cursor: CGPoint(x: 608, y: 760)))
    }

    func test_cancel_tears_down() {
        let (coordinator, host) = makeCoordinator()
        coordinator.enter(paneID: floatID, cursor: CGPoint(x: 608, y: 760))
        XCTAssertNotNil(pendingDwell)

        coordinator.cancel()

        XCTAssertFalse(coordinator.isActive)
        XCTAssertEqual(cancelledDwells, 1)
        XCTAssertTrue(host.subviews.isEmpty)
        XCTAssertNil(coordinator.commit(cursor: CGPoint(x: 404, y: 400)), "nothing commits after a cancel")
    }

    func test_empty_strip_previews_whole_canvas() {
        columns = []
        let (coordinator, _) = makeCoordinator()

        coordinator.enter(paneID: floatID, cursor: CGPoint(x: 600, y: 400))

        XCTAssertEqual(coordinator.currentTarget, .columnGap(index: 0))
        XCTAssertEqual(coordinator.previewForTesting.geometry, .emptyStrip(CGRect(x: 8, y: 8, width: 1184, height: 784)))
    }

    // MARK: - Fixtures

    private func makeCoordinator() -> (FloatDockCoordinator, NSView) {
        let host = FloatDockPreviewHostView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        previewHost = host
        let coordinator = FloatDockCoordinator(
            previewHost: host,
            columnsProvider: { [unowned self] in self.columns },
            hapticFeedbackPerformer: haptics,
            scheduleDwell: { [unowned self] _, action in
                self.pendingDwell = action
                return { [unowned self] in
                    self.cancelledDwells += 1
                    self.pendingDwell = nil
                }
            }
        )
        return (coordinator, host)
    }

    private nonisolated static func column(_ id: String, x: CGFloat, width: CGFloat = 400) -> ColumnPresentation {
        let frame = CGRect(x: x, y: 0, width: width, height: 800)
        return ColumnPresentation(
            columnID: PaneColumnID("col_\(id)"),
            frame: frame,
            panes: [PanePresentation(paneID: PaneID(id), columnID: PaneColumnID("col_\(id)"), frame: frame, emphasis: 1, isFocused: false)]
        )
    }
}

@MainActor
private final class HapticSpy: DragReorderHapticFeedbackPerforming {
    private(set) var events: [DragReorderHapticEvent] = []

    func performReorderAlignmentFeedback() {
        events.append(.alignment)
    }

    func performStructuralChangeFeedback() {
        events.append(.structural)
    }
}
