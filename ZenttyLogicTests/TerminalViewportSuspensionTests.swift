import AppKit
import XCTest
@testable import Zentty

/// Viewport sync suspension is owned: each operation that scales or animates
/// a container suspends under its own owner and resumes only that owner, so a
/// stale completion can't publish a scaled viewport while another owner still
/// scales the container.
@MainActor
final class TerminalViewportSuspensionTests: AppKitTestCase {
    func test_sync_resumes_only_once_every_owner_released() {
        var suspension = TerminalViewportSuspension()
        suspension.acquire(.floatLiftInPlace)
        suspension.acquire(.floatLiftScale)

        XCTAssertFalse(suspension.release(.floatLiftInPlace), "the lift scale still holds it")
        XCTAssertTrue(suspension.isSuspended)
        XCTAssertTrue(suspension.release(.floatLiftScale))
        XCTAssertFalse(suspension.isSuspended)
    }

    func test_acquiring_twice_needs_one_release() {
        var suspension = TerminalViewportSuspension()
        suspension.acquire(.pip)
        suspension.acquire(.pip)

        XCTAssertTrue(suspension.release(.pip))
    }

    func test_container_keeps_the_surface_suspended_while_another_owner_holds_it() {
        let (container, view) = makeContainer()

        container.suspendTerminalViewportSync(by: .dockSettle)
        container.setTerminalViewportSyncSuspended(true)
        XCTAssertEqual(view.isSuspended, true)

        XCTAssertFalse(container.resumeTerminalViewportSync(by: .dockSettle), "the strip zoom still holds it")
        XCTAssertEqual(view.isSuspended, true)
        XCTAssertEqual(container.terminalViewportSuspensionOwners, [.strip])

        container.setTerminalViewportSyncSuspended(false)
        XCTAssertEqual(view.isSuspended, false)
        XCTAssertFalse(container.isTerminalViewportSyncSuspended)
    }

    func test_strip_resume_does_not_end_a_pip_suspension() {
        let (container, view) = makeContainer(initialOwner: .pip)
        XCTAssertEqual(container.terminalViewportSuspensionOwners, [.pip])

        container.setTerminalViewportSyncSuspended(false)

        XCTAssertEqual(view.isSuspended, true, "a PiP stays frozen until it leaves PiP")
        XCTAssertTrue(container.resumeTerminalViewportSync(by: .pip))
        XCTAssertEqual(view.isSuspended, false)
    }

    // MARK: - Overlaps (review findings)

    func test_dock_landing_keeps_sync_suspended_while_peek_scales_the_strip() throws {
        FloatMotion.reduceMotionOverride = false
        defer { FloatMotion.reduceMotionOverride = nil }
        let adapters = SuspensionLoggingAdapters()
        let registry = PaneRuntimeRegistry(adapterFactory: { paneID in
            let adapter = SuspensionLoggingAdapter()
            adapters.byPaneID[paneID] = adapter
            return adapter
        })
        let strip = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 720), runtimeRegistry: registry)
        addTeardownBlock { MainActor.assumeIsolated { strip.prepareForTestingTearDown() } }
        let paneID = PaneID("docked")
        strip.render(PaneStripState(panes: [PaneState(id: paneID, title: "docked")], focusedPaneID: paneID))
        strip.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(adapters.byPaneID[paneID]?.view)

        let landed = expectation(description: "dock landed")
        strip.settleDockedPane(paneID, fromFrame: CGRect(x: 200, y: 200, width: 400, height: 280), in: strip) {
            landed.fulfill()
        }
        XCTAssertEqual(view.isSuspended, true, "frozen while it lands")
        strip.beginPeekZoomOut(animated: false)
        let unsuspendsBeforeLanding = view.log.filter { !$0 }.count

        wait(for: [landed], timeout: 2)

        XCTAssertEqual(view.isSuspended, true, "peek still scales the strip")
        XCTAssertEqual(view.log.filter { !$0 }.count, unsuspendsBeforeLanding, "the landing never resumed sync")

        strip.endPeekZoomIn(animated: false)
        XCTAssertEqual(view.isSuspended, false)
    }

    // MARK: - Fixtures

    private func makeContainer(
        initialOwner: TerminalViewportSuspensionOwner? = nil
    ) -> (PaneContainerView, SuspensionLoggingView) {
        let adapter = SuspensionLoggingAdapter()
        let pane = PaneState(id: PaneID("pane"), title: "pane")
        let runtime = PaneRuntime(pane: pane, adapter: adapter, metadataSink: { _, _ in }, eventSink: { _, _ in })
        let container = PaneContainerView(
            pane: pane,
            width: 400,
            height: 300,
            emphasis: 1,
            isFocused: false,
            runtime: runtime,
            theme: ZenttyTheme.fallback(for: nil),
            initialViewportSyncSuspended: initialOwner != nil,
            initialViewportSuspensionOwner: initialOwner ?? .strip
        )
        return (container, adapter.view)
    }
}

@MainActor
private final class SuspensionLoggingAdapters {
    var byPaneID: [PaneID: SuspensionLoggingAdapter] = [:]
}

@MainActor
private final class SuspensionLoggingAdapter: TerminalAdapter {
    let view = SuspensionLoggingView()
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?

    func makeTerminalView() -> NSView { view }
    func startSession(using request: TerminalSessionRequest) throws {}
    func close() {}
    func sendText(_ text: String) {}
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}
}

private final class SuspensionLoggingView: NSView, TerminalViewportSyncControlling {
    private(set) var isSuspended: Bool?
    private(set) var log: [Bool] = []

    func setViewportSyncSuspended(_ suspended: Bool) {
        isSuspended = suspended
        log.append(suspended)
    }
}
