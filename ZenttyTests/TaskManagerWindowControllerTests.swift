import AppKit
import XCTest
@testable import Zentty

@MainActor
final class TaskManagerWindowControllerTests: XCTestCase {
    func test_expandedPaneRemainsExpandedAcrossTimerRefresh() throws {
        let controller = makeController()
        controller.show(sender: nil)

        let outlineView = try XCTUnwrap(controller.window?.contentView?.firstDescendant(ofType: NSOutlineView.self))
        XCTAssertGreaterThan(outlineView.numberOfRows, 0)
        XCTAssertTrue(outlineView.isExpandable(outlineView.item(atRow: 0)!))

        outlineView.expandItem(outlineView.item(atRow: 0))
        XCTAssertTrue(outlineView.isItemExpanded(outlineView.item(atRow: 0)!))

        let refreshed = expectation(description: "timer refresh")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
            refreshed.fulfill()
        }
        wait(for: [refreshed], timeout: 3)

        XCTAssertTrue(outlineView.isItemExpanded(outlineView.item(atRow: 0)!))
    }

    func test_selectedPaneRemainsSelectedAcrossTimerRefresh() throws {
        let controller = makeController()
        controller.show(sender: nil)

        let outlineView = try XCTUnwrap(controller.window?.contentView?.firstDescendant(ofType: NSOutlineView.self))
        XCTAssertGreaterThan(outlineView.numberOfRows, 0)

        outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(controller.window?.makeFirstResponder(outlineView) ?? false)
        XCTAssertEqual(outlineView.selectedRow, 0)
        XCTAssertTrue(controller.window?.firstResponder === outlineView)

        let refreshed = expectation(description: "timer refresh")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
            refreshed.fulfill()
        }
        wait(for: [refreshed], timeout: 3)

        XCTAssertEqual(outlineView.selectedRow, 0)
        XCTAssertTrue(controller.window?.firstResponder === outlineView)
    }

    func test_taskManagerShowsNativeColumnHeaders() throws {
        let controller = makeController()
        controller.show(sender: nil)

        let outlineView = try XCTUnwrap(controller.window?.contentView?.firstDescendant(ofType: NSOutlineView.self))
        let headerView = try XCTUnwrap(outlineView.headerView)

        XCTAssertGreaterThan(headerView.frame.height, 0)
        XCTAssertEqual(outlineView.tableColumns.map(\.title), [
            "Pane",
            "Status",
            "CPU",
            "Memory",
            "Network",
            "Hottest Process",
            "Root PID",
        ])
    }

    private func makeController() -> TaskManagerWindowController {
        let controller = TaskManagerWindowController(
            paneSourcesProvider: {
                [
                    TaskManagerPaneSource(
                        windowID: WindowID("window-main"),
                        windowTitle: "Main Window",
                        worklaneID: WorklaneID("worklane-main"),
                        worklaneTitle: "Main",
                        paneID: PaneID("pane-main"),
                        paneTitle: "Pane",
                        statusText: "Idle",
                        rootPID: Int32(ProcessInfo.processInfo.processIdentifier),
                        isRemote: false,
                        currentWorkingDirectory: "/tmp"
                    ),
                ]
            },
            focusPaneHandler: { _, _, _ in },
            closePaneHandler: { _, _ in }
        )
        addTeardownBlock { @MainActor in
            controller.close()
        }
        return controller
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let view = self as? T {
            return view
        }

        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }

        return nil
    }
}
