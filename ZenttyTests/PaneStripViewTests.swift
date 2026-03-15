import AppKit
import XCTest
@testable import Zentty

final class PaneStripViewTests: XCTestCase {
    @MainActor
    func test_pane_frames_update_when_container_width_changes() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1400, height: 720))
        let state = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("editor")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        let wideFocusedWidth = paneStripView.descendantPaneViews()[1].frame.width
        let widePaneHeight = paneStripView.descendantPaneViews()[1].frame.height

        paneStripView.frame.size = NSSize(width: 900, height: 640)
        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        let compactFocusedWidth = paneStripView.descendantPaneViews()[1].frame.width
        let compactPaneHeight = paneStripView.descendantPaneViews()[1].frame.height

        XCTAssertLessThan(compactFocusedWidth, wideFocusedWidth)
        XCTAssertLessThan(compactPaneHeight, widePaneHeight)
    }

    @MainActor
    func test_pane_frames_grow_beyond_previous_fixed_height_when_container_is_tall() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 820))
        let state = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
            ],
            focusedPaneID: PaneID("editor")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(paneStripView.descendantPaneViews()[1].frame.height, 360)
    }

    @MainActor
    func test_focus_change_repositions_visible_panes() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 980, height: 680))
        let editorFocused = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
                makePane("shell"),
            ],
            focusedPaneID: PaneID("editor")
        )
        let testsFocused = PaneStripState(
            panes: [
                makePane("logs"),
                makePane("editor"),
                makePane("tests"),
                makePane("shell"),
            ],
            focusedPaneID: PaneID("tests")
        )

        paneStripView.render(editorFocused)
        paneStripView.layoutSubtreeIfNeeded()
        let initialFrames = Dictionary(uniqueKeysWithValues: paneStripView.descendantPaneViews().map { ($0.titleTextForTesting, $0.frame) })

        paneStripView.render(testsFocused)
        paneStripView.layoutSubtreeIfNeeded()
        let updatedFrames = Dictionary(uniqueKeysWithValues: paneStripView.descendantPaneViews().map { ($0.titleTextForTesting, $0.frame) })

        XCTAssertLessThan(updatedFrames["editor"]!.minX, initialFrames["editor"]!.minX)
        XCTAssertLessThan(updatedFrames["tests"]!.midX, initialFrames["tests"]!.midX)
    }

    @MainActor
    func test_workspace_switch_with_no_shared_panes_skips_cross_workspace_animation() {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 980, height: 680))
        let mainState = PaneStripState(
            panes: [
                PaneState(id: PaneID("main-shell"), title: "shell"),
            ],
            focusedPaneID: PaneID("main-shell")
        )
        let workspace2State = PaneStripState(
            panes: [
                PaneState(id: PaneID("workspace-2-shell"), title: "shell"),
            ],
            focusedPaneID: PaneID("workspace-2-shell")
        )

        paneStripView.render(mainState)
        paneStripView.layoutSubtreeIfNeeded()

        paneStripView.render(workspace2State)
        paneStripView.layoutSubtreeIfNeeded()

        XCTAssertFalse(paneStripView.lastRenderWasAnimatedForTesting)
    }

    @MainActor
    func test_split_reuses_existing_pane_views_and_only_starts_one_new_session() {
        let adapterFactory = TerminalAdapterFactorySpy()
        let runtimeRegistry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: 980, height: 680),
            runtimeRegistry: runtimeRegistry
        )
        let singlePane = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
            ],
            focusedPaneID: PaneID("shell")
        )
        let splitState = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("pane-1"), title: "pane 1"),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        paneStripView.render(singlePane)
        paneStripView.layoutSubtreeIfNeeded()
        let originalShellView = try? XCTUnwrap(paneStripView.descendantPaneViews().first)
        XCTAssertEqual(adapterFactory.adapters.map(\.startSessionCallCount), [1])

        paneStripView.render(splitState)
        paneStripView.layoutSubtreeIfNeeded()

        let paneViews = paneStripView.descendantPaneViews()
        XCTAssertEqual(paneViews.count, 2)
        XCTAssertTrue(paneViews.contains(where: { $0 === originalShellView }))
        XCTAssertEqual(adapterFactory.adapters.map(\.startSessionCallCount), [1, 1])
    }

    @MainActor
    func test_resize_reuses_existing_pane_views_and_does_not_restart_sessions() throws {
        let adapterFactory = TerminalAdapterFactorySpy()
        let runtimeRegistry = PaneRuntimeRegistry(adapterFactory: { paneID in
            adapterFactory.makeAdapter(for: paneID)
        })
        let paneStripView = PaneStripView(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 680),
            runtimeRegistry: runtimeRegistry
        )
        let state = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("editor"), title: "editor"),
            ],
            focusedPaneID: PaneID("editor")
        )

        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        let originalPaneViews = try XCTUnwrap(
            Dictionary(
                uniqueKeysWithValues: paneStripView.descendantPaneViews().map { paneView in
                    (paneView.paneID, paneView)
                }
            )
        )
        XCTAssertEqual(adapterFactory.adapters.map(\.startSessionCallCount), [1, 1])

        paneStripView.frame.size = NSSize(width: 1580, height: 820)
        paneStripView.render(state)
        paneStripView.layoutSubtreeIfNeeded()

        let resizedPaneViews = try XCTUnwrap(
            Dictionary(
                uniqueKeysWithValues: paneStripView.descendantPaneViews().map { paneView in
                    (paneView.paneID, paneView)
                }
            )
        )

        XCTAssertEqual(Set(resizedPaneViews.keys), Set(originalPaneViews.keys))
        for (paneID, paneView) in resizedPaneViews {
            XCTAssertTrue(paneView === originalPaneViews[paneID])
        }
        XCTAssertEqual(adapterFactory.adapters.map(\.startSessionCallCount), [1, 1])
    }

    @MainActor
    func test_single_pane_initially_fills_available_width_then_split_uses_column_widths() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let singlePane = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
            ],
            focusedPaneID: PaneID("shell")
        )
        let splitState = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("pane-1"), title: "pane 1"),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        paneStripView.render(singlePane)
        paneStripView.layoutSubtreeIfNeeded()
        let originalShellView = try XCTUnwrap(paneStripView.descendantPaneViews().first)
        let fullWidth = originalShellView.frame.width

        paneStripView.render(splitState)
        paneStripView.layoutSubtreeIfNeeded()
        let paneViews = paneStripView.descendantPaneViews()

        XCTAssertEqual(fullWidth, 1184, accuracy: 0.001)
        XCTAssertTrue(paneViews.contains(where: { $0 === originalShellView }))
        XCTAssertEqual(paneViews[0].frame.width, 587, accuracy: 0.001)
        XCTAssertEqual(paneViews[1].frame.width, 587, accuracy: 0.001)
    }

    @MainActor
    func test_first_split_keeps_symmetric_left_and_right_canvas_margins() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let splitState = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("pane-1"), title: "pane 1"),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        paneStripView.render(splitState)
        paneStripView.layoutSubtreeIfNeeded()

        let paneViews = paneStripView.descendantPaneViews().sorted { $0.frame.minX < $1.frame.minX }
        let leftMargin = try XCTUnwrap(paneViews.first?.frame.minX)
        let lastPaneMaxX = try XCTUnwrap(paneViews.last?.frame.maxX)
        let rightMargin = paneStripView.bounds.width - lastPaneMaxX

        XCTAssertEqual(leftMargin, rightMargin, accuracy: 0.001)
    }

    @MainActor
    func test_split_from_single_pane_seeds_new_pane_from_right_edge_of_original_pane() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let singlePane = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
            ],
            focusedPaneID: PaneID("shell")
        )
        let splitState = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("pane-1"), title: "pane 1"),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        paneStripView.render(singlePane)
        paneStripView.layoutSubtreeIfNeeded()
        let originalShellFrame = try XCTUnwrap(paneStripView.descendantPaneViews().first?.frame)
        let splitPresentation = PaneStripMotionController().presentation(
            for: splitState,
            in: paneStripView.bounds.size
        )

        paneStripView.render(splitState)

        let transition = try XCTUnwrap(paneStripView.lastInsertionTransitionForTesting)
        let finalFrame = try XCTUnwrap(
            splitPresentation.panes.first(where: { $0.paneID == PaneID("pane-1") })?.frame
                .offsetBy(dx: -splitPresentation.targetOffset, dy: 0)
        )

        XCTAssertEqual(transition.side, .right)
        XCTAssertEqual(transition.paneID, PaneID("pane-1"))
        XCTAssertGreaterThan(transition.initialFrame.minX, originalShellFrame.maxX)
        XCTAssertGreaterThan(transition.initialFrame.minX, finalFrame.minX)
    }

    @MainActor
    func test_split_from_multi_pane_seeds_new_pane_from_right_of_left_neighbor() throws {
        let paneStripView = PaneStripView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let twoPaneState = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("editor"), title: "editor"),
            ],
            focusedPaneID: PaneID("editor")
        )
        let splitState = PaneStripState(
            panes: [
                PaneState(id: PaneID("shell"), title: "shell"),
                PaneState(id: PaneID("editor"), title: "editor"),
                PaneState(id: PaneID("pane-1"), title: "pane 1"),
            ],
            focusedPaneID: PaneID("pane-1")
        )

        paneStripView.render(twoPaneState)
        paneStripView.layoutSubtreeIfNeeded()
        let editorFrame = try XCTUnwrap(
            paneStripView.descendantPaneViews().first(where: { $0.titleTextForTesting == "editor" })?.frame
        )

        paneStripView.render(splitState)

        let transition = try XCTUnwrap(paneStripView.lastInsertionTransitionForTesting)

        XCTAssertEqual(transition.side, .right)
        XCTAssertEqual(transition.paneID, PaneID("pane-1"))
        XCTAssertGreaterThan(transition.initialFrame.minX, editorFrame.maxX)
    }

    private func makePane(_ title: String) -> PaneState {
        PaneState(id: PaneID(title), title: title)
    }
}

@MainActor
private final class TerminalAdapterFactorySpy {
    private(set) var adapters: [PaneStripTerminalAdapterSpy] = []

    func makeAdapter(for paneID: PaneID) -> any TerminalAdapter {
        let adapter = PaneStripTerminalAdapterSpy(paneID: paneID)
        adapters.append(adapter)
        return adapter
    }
}

@MainActor
private final class PaneStripTerminalAdapterSpy: TerminalAdapter {
    let paneID: PaneID
    let terminalView = NSView()
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    private(set) var startSessionCallCount = 0
    private(set) var lastSurfaceActivity = TerminalSurfaceActivity()

    init(paneID: PaneID) {
        self.paneID = paneID
    }

    func makeTerminalView() -> NSView {
        terminalView
    }

    func startSession(using request: TerminalSessionRequest) throws {
        startSessionCallCount += 1
    }

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        lastSurfaceActivity = activity
    }
}

private extension NSView {
    func descendantPaneViews() -> [PaneContainerView] {
        var paneViews: [PaneContainerView] = []

        func walk(_ view: NSView) {
            if let paneView = view as? PaneContainerView {
                paneViews.append(paneView)
            }

            view.subviews.forEach(walk)
        }

        walk(self)
        return paneViews
    }
}
