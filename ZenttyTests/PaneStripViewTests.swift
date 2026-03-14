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

    private func makePane(_ title: String) -> PaneState {
        PaneState(id: PaneID(title), title: title)
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
