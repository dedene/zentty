import AppKit
import Carbon.HIToolbox
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

    func test_taskManagerAppliesInjectedThemeAndAppearanceToNativeControls() throws {
        let appearance = NSAppearance(named: .darkAqua)
        let theme = ZenttyTheme.fallback(for: appearance)
        let controller = makeController(appearance: appearance, theme: theme)
        controller.show(sender: nil)

        let window = try XCTUnwrap(controller.window)
        let contentView = try XCTUnwrap(window.contentView)
        let outlineView = try XCTUnwrap(contentView.firstDescendant(ofType: NSOutlineView.self))
        let searchField = try XCTUnwrap(contentView.firstDescendant(ofType: NSSearchField.self))
        let button = try XCTUnwrap(contentView.firstDescendantButton(titled: "Focus Pane"))
        let firstCell = try XCTUnwrap(outlineView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)

        XCTAssertEqual(window.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
        XCTAssertEqual(contentView.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
        XCTAssertEqual(outlineView.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
        XCTAssertEqual(searchField.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
        XCTAssertEqual(button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
        XCTAssertEqual(contentView.layer?.backgroundColor, theme.windowBackground.cgColor)
        XCTAssertEqual(outlineView.backgroundColor.themeToken, controller.tableBackgroundColorForTesting.themeToken)
        XCTAssertEqual(firstCell.textField?.textColor?.themeToken, theme.primaryText.themeToken)
    }

    func test_applyThemeUpdatesTaskManagerAppearanceAndVisibleCells() throws {
        let controller = makeController(
            appearance: NSAppearance(named: .aqua),
            theme: ZenttyTheme.fallback(for: NSAppearance(named: .aqua))
        )
        controller.show(sender: nil)

        let darkAppearance = NSAppearance(named: .darkAqua)
        let darkTheme = ZenttyTheme.fallback(for: darkAppearance)
        controller.applyAppearance(darkAppearance)
        controller.applyTheme(darkTheme)

        let window = try XCTUnwrap(controller.window)
        let contentView = try XCTUnwrap(window.contentView)
        let outlineView = try XCTUnwrap(contentView.firstDescendant(ofType: NSOutlineView.self))
        let firstCell = try XCTUnwrap(outlineView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)

        XCTAssertEqual(window.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
        XCTAssertEqual(outlineView.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
        XCTAssertEqual(contentView.layer?.backgroundColor, darkTheme.windowBackground.cgColor)
        XCTAssertEqual(outlineView.backgroundColor.themeToken, controller.tableBackgroundColorForTesting.themeToken)
        XCTAssertEqual(firstCell.textField?.textColor?.themeToken, darkTheme.primaryText.themeToken)
    }

    func test_commandWClosesTaskManagerWindow() throws {
        let controller = makeController()
        controller.show(sender: nil)

        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.isVisible)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_W)
        ))

        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertFalse(window.isVisible)
    }

    private func makeController(
        appearance: NSAppearance? = nil,
        theme: ZenttyTheme = ZenttyTheme.fallback(for: nil)
    ) -> TaskManagerWindowController {
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
            closePaneHandler: { _, _ in },
            appearance: appearance,
            theme: theme
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

    func firstDescendantButton(titled title: String) -> NSButton? {
        if let button = self as? NSButton, button.title == title {
            return button
        }

        for subview in subviews {
            if let match = subview.firstDescendantButton(titled: title) {
                return match
            }
        }

        return nil
    }
}
