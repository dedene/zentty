import AppKit
import GhosttyKit
import XCTest
@testable import Zentty

@MainActor
final class LibghosttyAdapterTests: XCTestCase {
    func test_make_terminal_view_returns_reusable_libghostty_view() {
        let adapter = LibghosttyAdapter(runtime: LibghosttyRuntimeProviderSpy())

        let firstView = adapter.makeTerminalView()
        let secondView = adapter.makeTerminalView()

        XCTAssertTrue(firstView === secondView)
        XCTAssertTrue(firstView is LibghosttyView)
    }

    func test_start_session_creates_surface_and_forwards_metadata() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)
        let terminalView = adapter.makeTerminalView()
        let request = TerminalSessionRequest(workingDirectory: "/tmp/project")
        let metadata = TerminalMetadata(
            title: "editor",
            currentWorkingDirectory: "/Users/peter/Development/Personal/zentty",
            processName: "zsh",
            gitBranch: "main"
        )
        var receivedMetadata: TerminalMetadata?

        adapter.metadataDidChange = { receivedMetadata = $0 }

        try adapter.startSession(using: request)

        XCTAssertEqual(runtime.makeSurfaceCallCount, 1)
        XCTAssertTrue(runtime.lastHostView === terminalView)
        XCTAssertEqual(runtime.lastRequest, request)

        runtime.lastMetadataHandler?(metadata)

        XCTAssertEqual(receivedMetadata, metadata)
    }

    func test_starting_visible_surface_refreshes_after_first_visibility_update() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)

        try adapter.startSession(using: TerminalSessionRequest())
        let surfaceController = try XCTUnwrap(runtime.lastSurfaceController)

        XCTAssertEqual(surfaceController.refreshCallCount, 0)

        adapter.setSurfaceActivity(TerminalSurfaceActivity(isVisible: true, isFocused: true))

        XCTAssertEqual(surfaceController.refreshCallCount, 1)
        XCTAssertEqual(surfaceController.focusValues.last, true)
    }

    func test_prepare_session_start_uses_inherited_config_from_source_surface() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let sourceAdapter = LibghosttyAdapter(runtime: runtime)
        let splitAdapter = LibghosttyAdapter(runtime: runtime)
        let inheritedConfig = ghostty_surface_config_new()

        try sourceAdapter.startSession(using: TerminalSessionRequest())
        runtime.lastSurfaceController?.inheritedConfig = inheritedConfig

        splitAdapter.prepareSessionStart(from: sourceAdapter)
        try splitAdapter.startSession(using: TerminalSessionRequest(inheritFromPaneID: PaneID("source")))

        XCTAssertEqual(runtime.makeSurfaceCallCount, 2)
        XCTAssertEqual(runtime.receivedConfigTemplates.count, 2)
        XCTAssertNil(runtime.receivedConfigTemplates[0])
        XCTAssertEqual(runtime.receivedConfigTemplates[1]?.context, inheritedConfig.context)
    }

    func test_copy_action_payload_copies_pwd_string_before_async_boundary() {
        let duplicated = strdup("/tmp/project")
        defer { free(duplicated) }

        let action = ghostty_action_s(
            tag: GHOSTTY_ACTION_PWD,
            action: ghostty_action_u(pwd: ghostty_action_pwd_s(pwd: duplicated))
        )

        let payload = copyLibghosttySurfaceActionPayload(from: action)

        XCTAssertEqual(payload, .pwd("/tmp/project"))
    }

    func test_copy_action_payload_copies_title_string_before_async_boundary() {
        let duplicated = strdup("shell")
        defer { free(duplicated) }

        let action = ghostty_action_s(
            tag: GHOSTTY_ACTION_SET_TITLE,
            action: ghostty_action_u(set_title: ghostty_action_set_title_s(title: duplicated))
        )

        let payload = copyLibghosttySurfaceActionPayload(from: action)

        XCTAssertEqual(payload, .setTitle("shell"))
    }
}

@MainActor
private final class LibghosttyRuntimeProviderSpy: LibghosttyRuntimeProviding {
    private(set) var makeSurfaceCallCount = 0
    private(set) weak var lastHostView: LibghosttyView?
    private(set) var lastMetadataHandler: ((TerminalMetadata) -> Void)?
    private(set) var lastRequest: TerminalSessionRequest?
    private(set) var lastSurfaceController: LibghosttySurfaceControllerSpy?
    private(set) var receivedConfigTemplates: [ghostty_surface_config_s?] = []

    func makeSurface(
        for hostView: LibghosttyView,
        request: TerminalSessionRequest,
        configTemplate: ghostty_surface_config_s?,
        metadataDidChange: @escaping (TerminalMetadata) -> Void
    ) throws -> any LibghosttySurfaceControlling {
        makeSurfaceCallCount += 1
        lastHostView = hostView
        lastRequest = request
        lastMetadataHandler = metadataDidChange
        receivedConfigTemplates.append(configTemplate)
        let surfaceController = LibghosttySurfaceControllerSpy()
        lastSurfaceController = surfaceController
        return surfaceController
    }
}

private final class LibghosttySurfaceControllerSpy: LibghosttySurfaceControlling {
    private(set) var refreshCallCount = 0
    private(set) var focusValues: [Bool] = []
    var inheritedConfig: ghostty_surface_config_s?
    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?) {}
    func setFocused(_ isFocused: Bool) { focusValues.append(isFocused) }
    func refresh() { refreshCallCount += 1 }
    func sendKey(event: NSEvent, action: TerminalKeyAction, text: String?, composing: Bool) -> Bool { true }
    func sendText(_ text: String) {}
    func inheritedConfig(for context: ghostty_surface_context_e) -> ghostty_surface_config_s? {
        inheritedConfig
    }
}
