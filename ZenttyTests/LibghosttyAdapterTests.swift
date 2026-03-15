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
        runtime.lastSurfaceController?.inheritedConfigContext = inheritedConfig.context

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

    func test_make_runtime_config_enables_clipboard_callbacks() {
        let config = LibghosttyRuntime.makeRuntimeConfig(
            userdata: UnsafeMutableRawPointer(bitPattern: 0x1)
        )

        XCTAssertTrue(config.supports_selection_clipboard)
        XCTAssertNotNil(config.wakeup_cb)
        XCTAssertNotNil(config.action_cb)
        XCTAssertNotNil(config.read_clipboard_cb)
        XCTAssertNotNil(config.confirm_read_clipboard_cb)
        XCTAssertNotNil(config.write_clipboard_cb)
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
    private(set) var bindingActions: [String] = []
    var selectionPresent = false
    var inheritedConfigContext: ghostty_surface_context_e?
    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?) {}
    func setFocused(_ isFocused: Bool) { focusValues.append(isFocused) }
    func refresh() { refreshCallCount += 1 }
    func sendKey(event: NSEvent, action: TerminalKeyAction, text: String?, composing: Bool) -> Bool { true }
    func sendMouseScroll(x: Double, y: Double, precision: Bool, momentum: NSEvent.Phase) {}
    func sendMousePosition(_ position: CGPoint, modifiers: NSEvent.ModifierFlags) {}
    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        modifiers: NSEvent.ModifierFlags
    ) {}
    func sendText(_ text: String) {}
    func performBindingAction(_ action: String) -> Bool {
        bindingActions.append(action)
        return true
    }
    func hasSelection() -> Bool { selectionPresent }
    func inheritedConfig(for context: ghostty_surface_context_e) -> ghostty_surface_config_s? {
        guard let inheritedConfigContext else {
            return nil
        }

        var config = ghostty_surface_config_new()
        config.context = inheritedConfigContext
        return config
    }
}
