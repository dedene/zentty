import AppKit
import XCTest
@testable import Zentty

@MainActor
final class DiscoveryIPCHandlerTests: XCTestCase {
    private var originalMainMenu: NSMenu?
    private weak var originalWindowsMenu: NSMenu?
    private var originalWindows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        originalMainMenu = NSApp.mainMenu
        originalWindowsMenu = NSApp.windowsMenu
        originalWindows = NSApp.windows
    }

    override func tearDown() {
        for window in NSApp.windows where originalWindows.contains(where: { $0 === window }) == false {
            if let controller = window.delegate as? MainWindowController {
                controller.closeWindowBypassingConfirmation()
            } else {
                window.close()
            }
        }

        NSApp.mainMenu = originalMainMenu
        NSApp.windowsMenu = originalWindowsMenu
        super.tearDown()
    }

    func test_discovery_handler_lists_windows_in_creation_order() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(
            runtimeRegistryFactory: { PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }) }
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.newWindow(nil)
        waitForWindows()

        let response = try DiscoveryIPCHandler.handle(
            request: AgentIPCRequest(
                kind: .discover,
                arguments: [],
                standardInput: nil,
                environment: [:],
                expectsResponse: true,
                subcommand: "windows"
            )
        )

        let windows = try XCTUnwrap(response.discoveredWindows)
        XCTAssertEqual(windows.map(\.order), [1, 2])
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.map(\.worklaneCount), [1, 1])
        XCTAssertEqual(windows.map(\.paneCount), [1, 1])
    }

    func test_discovery_handler_filters_worklanes_and_surfaces_control_tokens_only_when_requested() throws {
        NSApp.mainMenu = nil

        let delegate = AppDelegate(
            runtimeRegistryFactory: { PaneRuntimeRegistry(adapterFactory: { _ in MockTerminalAdapter() }) }
        )
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.newWindow(nil)
        waitForWindows()

        let controllers = delegate.windowControllersForTesting
        XCTAssertEqual(controllers.count, 2)

        let firstWorklaneID = WorklaneID("main-a")
        let firstPaneID = PaneID("pane-a")
        controllers[0].rootViewControllerForTesting.replaceWorklanes([
            WorklaneState(
                id: firstWorklaneID,
                title: "FIRST",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: firstPaneID, title: "shell-a")],
                    focusedPaneID: firstPaneID
                )
            ),
        ], activeWorklaneID: firstWorklaneID)

        let secondWorklaneID = WorklaneID("main-b")
        let secondPaneID = PaneID("pane-b")
        controllers[1].rootViewControllerForTesting.replaceWorklanes([
            WorklaneState(
                id: secondWorklaneID,
                title: "SECOND",
                paneStripState: PaneStripState(
                    panes: [PaneState(id: secondPaneID, title: "shell-b")],
                    focusedPaneID: secondPaneID
                )
            ),
        ], activeWorklaneID: secondWorklaneID)
        waitForLayout()

        let worklaneResponse = try DiscoveryIPCHandler.handle(
            request: AgentIPCRequest(
                kind: .discover,
                arguments: ["--window-id", controllers[1].windowIDForTesting.rawValue],
                standardInput: nil,
                environment: [:],
                expectsResponse: true,
                subcommand: "worklanes"
            )
        )
        XCTAssertEqual(worklaneResponse.discoveredWorklanes?.map(\.id), [secondWorklaneID.rawValue])

        let panesWithoutToken = try DiscoveryIPCHandler.handle(
            request: AgentIPCRequest(
                kind: .discover,
                arguments: ["--window-id", controllers[1].windowIDForTesting.rawValue],
                standardInput: nil,
                environment: [:],
                expectsResponse: true,
                subcommand: "panes"
            )
        )
        XCTAssertEqual(panesWithoutToken.discoveredPanes?.count, 1)
        XCTAssertNil(try XCTUnwrap(panesWithoutToken.discoveredPanes?.first).controlToken)

        let panesWithToken = try DiscoveryIPCHandler.handle(
            request: AgentIPCRequest(
                kind: .discover,
                arguments: [
                    "--window-id", controllers[1].windowIDForTesting.rawValue,
                    "--include-control-token",
                ],
                standardInput: nil,
                environment: [:],
                expectsResponse: true,
                subcommand: "panes"
            )
        )
        XCTAssertEqual(panesWithToken.discoveredPanes?.count, 1)
        XCTAssertNotNil(try XCTUnwrap(panesWithToken.discoveredPanes?.first).controlToken)
    }

    private func waitForWindows() {
        let opened = expectation(description: "windows opened")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { opened.fulfill() }
        wait(for: [opened], timeout: 2.0)
    }

    private func waitForLayout() {
        let settled = expectation(description: "layout settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { settled.fulfill() }
        wait(for: [settled], timeout: 2.0)
    }
}
