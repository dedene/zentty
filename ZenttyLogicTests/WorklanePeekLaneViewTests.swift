import AppKit
import XCTest
@testable import Zentty

@MainActor
final class WorklanePeekLaneViewTests: AppKitTestCase {

    func test_centering_neighbor_pane_notifies_geometry_change() {
        let carrier = makeCarrier()
        let worklane = makeWorklane(
            panes: [
                PaneState(id: PaneID("left"), title: "left", width: 420),
                PaneState(id: PaneID("right"), title: "right", width: 420),
            ],
            focusedPaneID: PaneID("left")
        )
        var geometryChangeCount = 0
        carrier.onGeometryChanged = {
            geometryChangeCount += 1
        }

        carrier.bind(
            worklane: worklane,
            theme: ZenttyTheme.fallback(for: nil),
            canvasSize: CGSize(width: 1200, height: 720),
            zoomScale: PaneStripView.zoomScale
        )
        geometryChangeCount = 0

        carrier.centerOnPane(PaneID("right"), animated: false)

        XCTAssertGreaterThan(geometryChangeCount, 0)
    }

    func test_pane_frame_in_carrier_tracks_horizontally_centered_split() throws {
        let carrier = makeCarrier()
        let worklane = makeWorklane(
            panes: [
                PaneState(id: PaneID("left"), title: "left", width: 420),
                PaneState(id: PaneID("middle"), title: "middle", width: 420),
                PaneState(id: PaneID("right"), title: "right", width: 420),
            ],
            focusedPaneID: PaneID("left")
        )

        carrier.bind(
            worklane: worklane,
            theme: ZenttyTheme.fallback(for: nil),
            canvasSize: CGSize(width: 1200, height: 720),
            zoomScale: PaneStripView.zoomScale
        )

        carrier.centerOnPane(PaneID("right"), animated: false)

        let rightFrame = try XCTUnwrap(carrier.paneFrameInCarrier(PaneID("right")))
        XCTAssertEqual(rightFrame.midX, carrier.bounds.midX, accuracy: 0.5)
        XCTAssertGreaterThan(rightFrame.width, 0)
        XCTAssertEqual(rightFrame.height, carrier.bounds.height, accuracy: 1.0)
    }

    func test_bind_shows_full_canvas_for_adjacent_split_preview() throws {
        let carrier = makeCarrier()
        let worklane = makeWorklane(
            panes: [
                PaneState(id: PaneID("left"), title: "left", width: 600),
                PaneState(id: PaneID("right"), title: "right", width: 600),
            ],
            focusedPaneID: PaneID("right")
        )

        carrier.bind(
            worklane: worklane,
            theme: ZenttyTheme.fallback(for: nil),
            canvasSize: CGSize(width: 1200, height: 720),
            zoomScale: PaneStripView.zoomScale
        )

        let leftFrame = try XCTUnwrap(carrier.paneFrameInCarrier(PaneID("left")))
        let rightFrame = try XCTUnwrap(carrier.paneFrameInCarrier(PaneID("right")))
        XCTAssertEqual(leftFrame.minX, carrier.bounds.minX, accuracy: 3.0)
        XCTAssertEqual(rightFrame.maxX, carrier.bounds.maxX, accuracy: 3.0)
    }

    func test_bind_centers_single_pane_preview_even_when_pane_is_narrower_than_canvas() throws {
        var adapters: [PaneID: WorklanePeekLaneTerminalAdapterSpy] = [:]
        let registry = PaneRuntimeRegistry { paneID in
            let adapter = WorklanePeekLaneTerminalAdapterSpy(paneID: paneID)
            adapters[paneID] = adapter
            return adapter
        }
        let carrier = WorklanePeekLaneView(runtimeRegistry: registry)
        carrier.frame = CGRect(x: 0, y: 0, width: 480, height: 288)
        carrier.layoutSubtreeIfNeeded()
        addTeardownBlock {
            MainActor.assumeIsolated {
                carrier.detach()
            }
        }
        let worklane = makeWorklane(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell", width: 640),
            ],
            focusedPaneID: PaneID("shell")
        )

        carrier.bind(
            worklane: worklane,
            theme: ZenttyTheme.fallback(for: nil),
            canvasSize: CGSize(width: 1200, height: 720),
            zoomScale: PaneStripView.zoomScale
        )

        let shellFrame = try XCTUnwrap(carrier.paneFrameInCarrier(PaneID("shell")))
        let terminalView = try XCTUnwrap(adapters[PaneID("shell")]?.terminalView)
        XCTAssertEqual(shellFrame.midX, carrier.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(terminalView.viewportSyncSuspensionUpdates.first, true)
        XCTAssertEqual(terminalView.forceViewportSyncCallCount, 0)
    }

    func test_bind_tags_preview_terminal_diagnostics_context_as_neighbor() throws {
        var adapters: [PaneID: WorklanePeekLaneTerminalAdapterSpy] = [:]
        let registry = PaneRuntimeRegistry { paneID in
            let adapter = WorklanePeekLaneTerminalAdapterSpy(paneID: paneID)
            adapters[paneID] = adapter
            return adapter
        }
        let carrier = WorklanePeekLaneView(runtimeRegistry: registry)
        carrier.frame = CGRect(x: 0, y: 0, width: 480, height: 288)
        carrier.layoutSubtreeIfNeeded()
        addTeardownBlock {
            MainActor.assumeIsolated {
                carrier.detach()
                TerminalViewportDiagnostics.shared.setEnabled(false)
                TerminalViewportDiagnostics.shared.clearForTesting()
                TerminalViewportDiagnostics.shared.onRecord = nil
            }
        }

        TerminalViewportDiagnostics.shared.clearForTesting()
        TerminalViewportDiagnostics.shared.setEnabled(true)

        let worklane = makeWorklane(
            id: WorklaneID("lane-preview"),
            panes: [PaneState(id: PaneID("shell"), title: "shell", width: 640)],
            focusedPaneID: PaneID("shell")
        )

        carrier.bind(
            worklane: worklane,
            theme: ZenttyTheme.fallback(for: nil),
            canvasSize: CGSize(width: 1200, height: 720),
            zoomScale: PaneStripView.zoomScale
        )

        let terminalView = try XCTUnwrap(adapters[PaneID("shell")]?.terminalView)
        let latestContext = try XCTUnwrap(terminalView.viewportDiagnosticsContexts.last)
        XCTAssertEqual(latestContext.paneID, PaneID("shell"))
        XCTAssertEqual(latestContext.worklaneID, WorklaneID("lane-preview"))
        XCTAssertEqual(latestContext.laneRole, .peekNeighbor)
        XCTAssertEqual(latestContext.containerBounds?.width, 640)
        XCTAssertGreaterThan(latestContext.containerBounds?.height ?? 0, 700)

        let events = TerminalViewportDiagnostics.shared.eventsForTesting()
        let sources = events.map(\.source)
        XCTAssertTrue(sources.contains(.peekNeighborBind))
        XCTAssertTrue(sources.contains(.initialSuspension))
        XCTAssertTrue(sources.contains(.paneContainerReparent))
        XCTAssertTrue(
            events
                .filter { [.initialSuspension, .paneContainerReparent].contains($0.source) }
                .allSatisfy {
                    $0.context.worklaneID == WorklaneID("lane-preview")
                        && $0.context.laneRole == .peekNeighbor
                        && $0.context.isZoomedOut == true
                }
        )
        XCTAssertTrue(events.first?.context.note?.contains("singlePanePreviewPaneID=shell") == true)
        XCTAssertTrue(sources.contains(.paneMounted))
    }

    func test_detach_does_not_resume_neighbor_terminal_viewport_sync() throws {
        var adapters: [PaneID: WorklanePeekLaneTerminalAdapterSpy] = [:]
        let registry = PaneRuntimeRegistry { paneID in
            let adapter = WorklanePeekLaneTerminalAdapterSpy(paneID: paneID)
            adapters[paneID] = adapter
            return adapter
        }
        let carrier = WorklanePeekLaneView(runtimeRegistry: registry)
        carrier.frame = CGRect(x: 0, y: 0, width: 480, height: 288)
        carrier.layoutSubtreeIfNeeded()
        addTeardownBlock {
            MainActor.assumeIsolated {
                TerminalViewportDiagnostics.shared.setEnabled(false)
                TerminalViewportDiagnostics.shared.clearForTesting()
                TerminalViewportDiagnostics.shared.onRecord = nil
            }
        }
        let paneID = PaneID("shell")
        let worklane = makeWorklane(
            id: WorklaneID("lane-preview"),
            panes: [PaneState(id: paneID, title: "shell", width: 640)],
            focusedPaneID: paneID
        )
        carrier.bind(
            worklane: worklane,
            theme: ZenttyTheme.fallback(for: nil),
            canvasSize: CGSize(width: 1200, height: 720),
            zoomScale: PaneStripView.zoomScale
        )
        let terminalView = try XCTUnwrap(adapters[paneID]?.terminalView)
        terminalView.clearViewportSyncSuspensionUpdatesForTesting()

        TerminalViewportDiagnostics.shared.clearForTesting()
        TerminalViewportDiagnostics.shared.setEnabled(true)
        carrier.detach()

        XCTAssertFalse(terminalView.viewportSyncSuspensionUpdates.contains(false))
        let events = TerminalViewportDiagnostics.shared.eventsForTesting()
        let sources = events.map(\.source)
        XCTAssertEqual(sources.first, .peekNeighborDetach)
        XCTAssertFalse(sources.contains(.peekNeighborEndZoomOut))
        XCTAssertFalse(
            events.contains {
                $0.source == .syncUnsuspended && $0.context.laneRole == .peekNeighbor
            }
        )
    }

    func test_configure_neighbor_lanes_prewarms_offscreen_lookahead() throws {
        let peekView = WorklanePeekView(frame: CGRect(x: 0, y: 0, width: 1200, height: 720))
        peekView.placeHUDStably(targetZoomScale: PaneStripView.zoomScale)
        let registry = PaneRuntimeRegistry { paneID in
            WorklanePeekLaneTerminalAdapterSpy(paneID: paneID)
        }
        let worklanes = (0..<5).map { index in
            makeWorklane(
                id: WorklaneID("lane-\(index)"),
                panes: [PaneState(id: PaneID("pane-\(index)"), title: "pane-\(index)", width: 1200)],
                focusedPaneID: PaneID("pane-\(index)")
            )
        }
        addTeardownBlock {
            MainActor.assumeIsolated {
                peekView.detach()
            }
        }

        peekView.configureNeighborLanes(
            worklanes: worklanes,
            activeIndex: 2,
            canvasSize: CGSize(width: 1200, height: 720),
            zoomScale: PaneStripView.zoomScale,
            runtimeRegistry: registry,
            theme: ZenttyTheme.fallback(for: nil)
        )

        XCTAssertEqual(
            peekView.peekVisibleWorklaneIDs,
            Set((0..<5).map { WorklaneID("lane-\($0)") })
        )
    }

    func test_panning_to_next_worklane_resets_previous_adjacent_preview_to_full_canvas() throws {
        let peekView = WorklanePeekView(frame: CGRect(x: 0, y: 0, width: 1200, height: 720))
        peekView.placeHUDStably(targetZoomScale: PaneStripView.zoomScale)
        let registry = PaneRuntimeRegistry { paneID in
            WorklanePeekLaneTerminalAdapterSpy(paneID: paneID)
        }
        let worklanes = [
            makeWorklane(
                id: WorklaneID("active"),
                panes: [PaneState(id: PaneID("active"), title: "active", width: 1200)],
                focusedPaneID: PaneID("active")
            ),
            makeWorklane(
                id: WorklaneID("middle"),
                panes: [
                    PaneState(id: PaneID("middle-left"), title: "middle-left", width: 600),
                    PaneState(id: PaneID("middle-right"), title: "middle-right", width: 600),
                ],
                focusedPaneID: PaneID("middle-left")
            ),
            makeWorklane(
                id: WorklaneID("next"),
                panes: [PaneState(id: PaneID("next"), title: "next", width: 1200)],
                focusedPaneID: PaneID("next")
            ),
        ]
        addTeardownBlock {
            MainActor.assumeIsolated {
                peekView.detach()
            }
        }

        peekView.configureNeighborLanes(
            worklanes: worklanes,
            activeIndex: 0,
            canvasSize: CGSize(width: 1200, height: 720),
            zoomScale: PaneStripView.zoomScale,
            runtimeRegistry: registry,
            theme: ZenttyTheme.fallback(for: nil)
        )

        peekView.centerOn(worklaneID: WorklaneID("middle"), animated: false)
        peekView.centerHorizontally(paneID: PaneID("middle-right"), animated: false)
        let middleCarrier = try XCTUnwrap(carrier(in: peekView, containing: PaneID("middle-right")))
        let centeredRightFrame = try XCTUnwrap(middleCarrier.paneFrameInCarrier(PaneID("middle-right")))
        XCTAssertEqual(centeredRightFrame.midX, middleCarrier.bounds.midX, accuracy: 0.5)

        peekView.centerOn(worklaneID: WorklaneID("next"), animated: false)

        let leftFrame = try XCTUnwrap(middleCarrier.paneFrameInCarrier(PaneID("middle-left")))
        let rightFrame = try XCTUnwrap(middleCarrier.paneFrameInCarrier(PaneID("middle-right")))
        let bandMinX = middleCarrier.bounds.midX - (1200 * PaneStripView.zoomScale / 2)
        let bandMaxX = middleCarrier.bounds.midX + (1200 * PaneStripView.zoomScale / 2)
        XCTAssertEqual(leftFrame.minX, bandMinX, accuracy: 3.0)
        XCTAssertEqual(rightFrame.maxX, bandMaxX, accuracy: 4.0)
    }

    func test_centered_neighbor_split_keeps_sibling_panes_inside_carrier() throws {
        let peekView = WorklanePeekView(frame: CGRect(x: 0, y: 0, width: 1200, height: 720))
        peekView.placeHUDStably(targetZoomScale: PaneStripView.zoomScale)
        let registry = PaneRuntimeRegistry { paneID in
            WorklanePeekLaneTerminalAdapterSpy(paneID: paneID)
        }
        let worklanes = [
            makeWorklane(
                id: WorklaneID("active"),
                panes: [PaneState(id: PaneID("active"), title: "active", width: 1200)],
                focusedPaneID: PaneID("active")
            ),
            makeWorklane(
                id: WorklaneID("middle"),
                panes: [
                    PaneState(id: PaneID("middle-left"), title: "middle-left", width: 600),
                    PaneState(id: PaneID("middle-right"), title: "middle-right", width: 600),
                ],
                focusedPaneID: PaneID("middle-left")
            ),
        ]
        addTeardownBlock {
            MainActor.assumeIsolated {
                peekView.detach()
            }
        }

        peekView.configureNeighborLanes(
            worklanes: worklanes,
            activeIndex: 0,
            canvasSize: CGSize(width: 1200, height: 720),
            zoomScale: PaneStripView.zoomScale,
            runtimeRegistry: registry,
            theme: ZenttyTheme.fallback(for: nil)
        )

        peekView.centerOn(worklaneID: WorklaneID("middle"), animated: false)
        peekView.centerHorizontally(paneID: PaneID("middle-right"), animated: false)
        let carrier = try XCTUnwrap(carrier(in: peekView, containing: PaneID("middle-right")))
        let leftWhenRightCentered = try XCTUnwrap(carrier.paneFrameInCarrier(PaneID("middle-left")))
        XCTAssertGreaterThanOrEqual(leftWhenRightCentered.minX, carrier.bounds.minX - 3.0)

        peekView.centerHorizontally(paneID: PaneID("middle-left"), animated: false)
        let rightWhenLeftCentered = try XCTUnwrap(carrier.paneFrameInCarrier(PaneID("middle-right")))
        XCTAssertLessThanOrEqual(rightWhenLeftCentered.maxX, carrier.bounds.maxX + 3.0)
    }

    func test_reset_cancels_centering() throws {
        let carrier = makeCarrier()
        let worklane = makeWorklane(
            panes: [
                PaneState(id: PaneID("left"), title: "left", width: 600),
                PaneState(id: PaneID("right"), title: "right", width: 600),
            ],
            focusedPaneID: PaneID("left")
        )

        carrier.bind(
            worklane: worklane,
            theme: ZenttyTheme.fallback(for: nil),
            canvasSize: CGSize(width: 1200, height: 720),
            zoomScale: PaneStripView.zoomScale
        )

        carrier.centerOnPane(PaneID("right"), animated: true)
        carrier.showFullCanvas()

        let animationWouldHaveCompleted = expectation(description: "pane centering animation would have completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            animationWouldHaveCompleted.fulfill()
        }
        wait(for: [animationWouldHaveCompleted], timeout: 1.0)

        let leftFrame = try XCTUnwrap(carrier.paneFrameInCarrier(PaneID("left")))
        let rightFrame = try XCTUnwrap(carrier.paneFrameInCarrier(PaneID("right")))
        XCTAssertEqual(leftFrame.minX, carrier.bounds.minX, accuracy: 3.0)
        XCTAssertEqual(rightFrame.maxX, carrier.bounds.maxX, accuracy: 3.0)
    }

    private func makeCarrier() -> WorklanePeekLaneView {
        let registry = PaneRuntimeRegistry { paneID in
            WorklanePeekLaneTerminalAdapterSpy(paneID: paneID)
        }
        let carrier = WorklanePeekLaneView(runtimeRegistry: registry)
        carrier.frame = CGRect(x: 0, y: 0, width: 480, height: 288)
        carrier.layoutSubtreeIfNeeded()
        addTeardownBlock {
            MainActor.assumeIsolated {
                carrier.detach()
            }
        }
        return carrier
    }

    private func makeWorklane(
        id: WorklaneID = WorklaneID("neighbor"),
        panes: [PaneState],
        focusedPaneID: PaneID
    ) -> WorklaneState {
        WorklaneState(
            id: id,
            title: "neighbor",
            paneStripState: PaneStripState(panes: panes, focusedPaneID: focusedPaneID)
        )
    }

    private func carrier(in peekView: WorklanePeekView, containing paneID: PaneID) -> WorklanePeekLaneView? {
        peekView.subviews
            .compactMap { $0 as? WorklanePeekLaneView }
            .first { $0.containsPane(paneID) }
    }
}

private final class WorklanePeekLaneTerminalAdapterSpy: TerminalAdapter {
    let paneID: PaneID
    let terminalView = WorklanePeekLaneTerminalViewSpy()
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?

    init(paneID: PaneID) {
        self.paneID = paneID
    }

    func makeTerminalView() -> NSView {
        terminalView
    }

    func startSession(using request: TerminalSessionRequest) throws {}
    func close() {}
    func sendText(_ text: String) {}
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}
}

private final class WorklanePeekLaneTerminalViewSpy: NSView, TerminalFocusReporting, TerminalFocusTargetProviding, TerminalScrollRouting, TerminalContextMenuConfiguring, TerminalViewportSyncControlling, TerminalViewportDiagnosticsContextConfiguring {
    var onFocusDidChange: ((Bool) -> Void)?
    var onScrollWheel: ((NSEvent) -> Bool)?
    var contextMenuBuilder: ((NSEvent, NSMenu?) -> NSMenu?)?
    private(set) var viewportSyncSuspensionUpdates: [Bool] = []
    private(set) var forceViewportSyncCallCount = 0
    private(set) var viewportDiagnosticsContexts: [TerminalViewportDiagnostics.Context] = []

    var terminalFocusTargetView: NSView {
        self
    }

    func setViewportSyncSuspended(_ suspended: Bool) {
        viewportSyncSuspensionUpdates.append(suspended)
    }

    func clearViewportSyncSuspensionUpdatesForTesting() {
        viewportSyncSuspensionUpdates.removeAll()
    }

    func forceViewportSync() {
        forceViewportSyncCallCount += 1
    }

    func updateViewportDiagnosticsContext(_ context: TerminalViewportDiagnostics.Context) {
        viewportDiagnosticsContexts.append(context)
    }
}
