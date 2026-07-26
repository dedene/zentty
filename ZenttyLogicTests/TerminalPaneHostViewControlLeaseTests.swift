import AppKit
import XCTest
@testable import Zentty

/// Detached component tests for the companion control-lease geometry (§2.6): the
/// terminal view is framed at the phone's leased grid size and centered, the pane
/// dims around it, and everything returns to a pane-filling frame on release.
@MainActor
final class TerminalPaneHostViewControlLeaseTests: XCTestCase {
    private func makeHost(
        leasedPointSize: CGSize,
        paneSize: CGSize = CGSize(width: 800, height: 600)
    ) -> (TerminalPaneHostView, ControlLeaseTerminalAdapterSpy) {
        let adapter = ControlLeaseTerminalAdapterSpy(leasedPointSize: leasedPointSize)
        let hostView = TerminalPaneHostView(adapter: adapter)
        hostView.frame = NSRect(origin: .zero, size: paneSize)
        hostView.layoutSubtreeIfNeeded()
        addTeardownBlock {
            hostView.endControlLease()
            hostView.removeFromSuperview()
        }
        return (hostView, adapter)
    }

    // MARK: - Centering maths

    func test_centered_lease_frame_centers_the_grid_in_the_pane() {
        let frame = TerminalPaneHostView.centeredLeaseFrame(
            forLeasedSize: CGSize(width: 300, height: 200),
            in: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertEqual(frame, CGRect(x: 250, y: 200, width: 300, height: 200))
    }

    func test_centered_lease_frame_floors_odd_offsets_to_whole_points() {
        let frame = TerminalPaneHostView.centeredLeaseFrame(
            forLeasedSize: CGSize(width: 301, height: 201),
            in: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertEqual(frame.origin.x, 249)
        XCTAssertEqual(frame.origin.y, 199)
    }

    func test_centered_lease_frame_clamps_a_grid_larger_than_the_pane() {
        let frame = TerminalPaneHostView.centeredLeaseFrame(
            forLeasedSize: CGSize(width: 1200, height: 400),
            in: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        XCTAssertEqual(frame, CGRect(x: 0, y: 100, width: 800, height: 400))
    }

    // MARK: - Host geometry

    func test_lease_centers_the_terminal_view_at_the_leased_size() {
        let (hostView, adapter) = makeHost(leasedPointSize: CGSize(width: 400, height: 300))

        XCTAssertTrue(hostView.beginControlLease(cols: 45, rows: 30, deviceName: "iPhone", onTakeBack: {}))

        XCTAssertEqual(adapter.appliedLeases.map(\.cols), [45])
        XCTAssertEqual(
            hostView.terminalViewForTesting.frame,
            CGRect(x: 200, y: 150, width: 400, height: 300)
        )
    }

    func test_lease_never_draws_outside_the_pane_when_the_grid_overflows() {
        let (hostView, _) = makeHost(
            leasedPointSize: CGSize(width: 2000, height: 300),
            paneSize: CGSize(width: 800, height: 600)
        )

        hostView.beginControlLease(cols: 220, rows: 30, deviceName: "iPhone", onTakeBack: {})

        let frame = hostView.terminalViewForTesting.frame
        XCTAssertTrue(hostView.bounds.contains(frame))
        XCTAssertEqual(frame.width, hostView.bounds.width)
    }

    func test_pane_resize_during_a_lease_recenters_the_grid() {
        let (hostView, _) = makeHost(leasedPointSize: CGSize(width: 400, height: 300))

        hostView.beginControlLease(cols: 45, rows: 30, deviceName: "iPhone", onTakeBack: {})
        hostView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        hostView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            hostView.terminalViewForTesting.frame,
            CGRect(x: 100, y: 50, width: 400, height: 300)
        )
    }

    func test_repeat_lease_updates_geometry_and_grid_label_in_place() {
        let (hostView, adapter) = makeHost(leasedPointSize: CGSize(width: 400, height: 300))

        hostView.beginControlLease(cols: 45, rows: 30, deviceName: "iPhone", onTakeBack: {})
        let placeholder = hostView.subviews.compactMap { $0 as? CompanionLeasePlaceholderView }.first

        adapter.leasedPointSize = CGSize(width: 200, height: 100)
        hostView.beginControlLease(cols: 22, rows: 10, deviceName: "iPad Pro", onTakeBack: {})

        XCTAssertEqual(hostView.subviews.compactMap { $0 as? CompanionLeasePlaceholderView }.count, 1)
        XCTAssertTrue(placeholder === hostView.subviews.compactMap { $0 as? CompanionLeasePlaceholderView }.first)
        XCTAssertEqual(placeholder?.gridTextForTesting, "22 × 10")
        XCTAssertEqual(placeholder?.messageTextForTesting.contains("iPad Pro"), true)
        XCTAssertEqual(
            hostView.terminalViewForTesting.frame,
            CGRect(x: 300, y: 250, width: 200, height: 100)
        )
    }

    func test_scrim_cutout_tracks_the_centered_grid() {
        let (hostView, _) = makeHost(leasedPointSize: CGSize(width: 400, height: 300))

        hostView.beginControlLease(cols: 45, rows: 30, deviceName: "iPhone", onTakeBack: {})

        let placeholder = hostView.subviews.compactMap { $0 as? CompanionLeasePlaceholderView }.first
        XCTAssertEqual(placeholder?.liveGridRectForTesting, CGRect(x: 200, y: 150, width: 400, height: 300))
    }

    // MARK: - Release

    func test_release_restores_the_pane_filling_frame() {
        let (hostView, adapter) = makeHost(leasedPointSize: CGSize(width: 400, height: 300))

        hostView.beginControlLease(cols: 45, rows: 30, deviceName: "iPhone", onTakeBack: {})
        hostView.endControlLease()

        XCTAssertEqual(adapter.releaseCallCount, 1)
        XCTAssertEqual(hostView.terminalViewForTesting.frame, hostView.bounds)
        XCTAssertFalse(hostView.isUnderControlLeaseForTesting)
    }

    func test_release_restores_tracking_after_a_resize_held_during_the_lease() {
        let (hostView, _) = makeHost(leasedPointSize: CGSize(width: 400, height: 300))

        hostView.beginControlLease(cols: 45, rows: 30, deviceName: "iPhone", onTakeBack: {})
        hostView.frame = NSRect(x: 0, y: 0, width: 500, height: 350)
        hostView.layoutSubtreeIfNeeded()
        hostView.endControlLease()

        XCTAssertEqual(hostView.terminalViewForTesting.frame, hostView.bounds)

        hostView.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        hostView.layoutSubtreeIfNeeded()

        XCTAssertEqual(hostView.terminalViewForTesting.frame, hostView.bounds)
    }

    func test_frame_restores_before_the_adapter_resumes_viewport_sync() {
        let (hostView, adapter) = makeHost(leasedPointSize: CGSize(width: 400, height: 300))

        hostView.beginControlLease(cols: 45, rows: 30, deviceName: "iPhone", onTakeBack: {})
        adapter.onRelease = { [weak hostView] in
            XCTAssertEqual(hostView?.terminalViewForTesting.frame, hostView?.bounds)
        }
        hostView.endControlLease()

        XCTAssertEqual(adapter.releaseCallCount, 1)
    }

    func test_unleased_pane_keeps_filling_its_bounds() {
        let (hostView, _) = makeHost(leasedPointSize: CGSize(width: 400, height: 300))

        hostView.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        hostView.layoutSubtreeIfNeeded()

        XCTAssertEqual(hostView.terminalViewForTesting.frame, hostView.bounds)
    }
}

/// Detached component tests for the grid-size line on the lease card.
@MainActor
final class CompanionLeasePlaceholderGridLineTests: XCTestCase {
    func test_grid_line_renders_with_a_multiplication_sign() {
        let view = CompanionLeasePlaceholderView(deviceName: "iPhone", gridSize: (cols: 45, rows: 30), onTakeBack: {})

        XCTAssertEqual(view.gridTextForTesting, "45 × 30")
        XCTAssertFalse(view.isGridLineHiddenForTesting)
    }

    func test_grid_line_hides_without_a_grid() {
        let view = CompanionLeasePlaceholderView(deviceName: "iPhone", onTakeBack: {})

        XCTAssertTrue(view.isGridLineHiddenForTesting)
        XCTAssertEqual(view.gridTextForTesting, "")
    }

    func test_update_rewrites_both_lines() {
        let view = CompanionLeasePlaceholderView(deviceName: "iPhone", gridSize: (cols: 45, rows: 30), onTakeBack: {})

        view.update(deviceName: "iPad Pro", gridSize: (cols: 80, rows: 24))

        XCTAssertEqual(view.gridTextForTesting, "80 × 24")
        XCTAssertTrue(view.messageTextForTesting.contains("iPad Pro"))
    }

    func test_live_grid_rect_drives_the_scrim_cutout() {
        let view = CompanionLeasePlaceholderView(deviceName: "iPhone", gridSize: (cols: 45, rows: 30), onTakeBack: {})

        XCTAssertNil(view.liveGridRectForTesting)
        view.setLiveGridRect(CGRect(x: 10, y: 20, width: 100, height: 50))
        XCTAssertEqual(view.liveGridRectForTesting, CGRect(x: 10, y: 20, width: 100, height: 50))
        view.setLiveGridRect(nil)
        XCTAssertNil(view.liveGridRectForTesting)
    }
}

/// Terminal view stub that reports a leased viewport the way the libghostty
/// scroll host does, without needing a live surface.
private final class ControlLeaseTerminalViewSpy: NSView, TerminalLeasedViewportSizing {
    var leasedViewportPointSize: CGSize?
}

private final class ControlLeaseTerminalAdapterSpy: TerminalAdapter, TerminalControlLeasing {
    let terminalView = ControlLeaseTerminalViewSpy()
    var hasScrollback = false
    var cellWidth: CGFloat = 8
    var cellHeight: CGFloat = 16
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?

    /// Point-space size the stubbed surface reports while leased.
    var leasedPointSize: CGSize
    var onRelease: (() -> Void)?
    private(set) var appliedLeases: [(cols: Int, rows: Int)] = []
    private(set) var releaseCallCount = 0

    init(leasedPointSize: CGSize) {
        self.leasedPointSize = leasedPointSize
    }

    func makeTerminalView() -> NSView {
        terminalView
    }

    func startSession(using request: TerminalSessionRequest) throws {}
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}
    func sendText(_ text: String) {}
    func close() {}

    @discardableResult
    func applyControlLease(cols: Int, rows: Int) -> Bool {
        appliedLeases.append((cols: cols, rows: rows))
        terminalView.leasedViewportPointSize = leasedPointSize
        return true
    }

    func releaseControlLease() {
        releaseCallCount += 1
        terminalView.leasedViewportPointSize = nil
        onRelease?()
    }
}
