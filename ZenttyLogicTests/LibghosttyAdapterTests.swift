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

    func test_hidden_live_surface_does_not_refresh_until_it_becomes_visible() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)

        try adapter.startSession(using: TerminalSessionRequest())
        let surfaceController = try XCTUnwrap(runtime.lastSurfaceController)

        adapter.setSurfaceActivity(
            TerminalSurfaceActivity(
                keepsRuntimeLive: true,
                isVisible: false,
                isFocused: false
            )
        )
        XCTAssertEqual(surfaceController.refreshCallCount, 0)
        XCTAssertEqual(surfaceController.focusValues.last, false)

        adapter.setSurfaceActivity(
            TerminalSurfaceActivity(
                keepsRuntimeLive: true,
                isVisible: true,
                isFocused: false
            )
        )

        XCTAssertEqual(surfaceController.refreshCallCount, 1)
        XCTAssertEqual(surfaceController.focusValues.last, false)
    }

    func test_hidden_live_surface_still_forwards_progress_events() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)
        var receivedEvent: TerminalEvent?

        adapter.eventDidOccur = { receivedEvent = $0 }

        try adapter.startSession(using: TerminalSessionRequest())
        adapter.setSurfaceActivity(
            TerminalSurfaceActivity(
                keepsRuntimeLive: true,
                isVisible: false,
                isFocused: false
            )
        )

        let report = TerminalProgressReport(state: .indeterminate, progress: nil)
        runtime.lastEventHandler?(.progressReport(report))

        XCTAssertEqual(receivedEvent, .progressReport(report))
    }

    func test_repeated_surface_activity_does_not_resend_focus_or_refresh() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)

        try adapter.startSession(using: TerminalSessionRequest())
        let surfaceController = try XCTUnwrap(runtime.lastSurfaceController)

        adapter.setSurfaceActivity(TerminalSurfaceActivity(isVisible: true, isFocused: true))
        let focusValuesAfterFirstUpdate = surfaceController.focusValues
        let refreshCallCountAfterFirstUpdate = surfaceController.refreshCallCount

        adapter.setSurfaceActivity(TerminalSurfaceActivity(isVisible: true, isFocused: true))

        XCTAssertEqual(surfaceController.focusValues, focusValuesAfterFirstUpdate)
        XCTAssertEqual(surfaceController.refreshCallCount, refreshCallCountAfterFirstUpdate)
    }

    func test_return_key_emits_user_submitted_input_event() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)
        var receivedEvents: [TerminalEvent] = []

        adapter.eventDidOccur = { receivedEvents.append($0) }

        _ = adapter.makeTerminalView()
        try adapter.startSession(using: TerminalSessionRequest())

        let hostView = try XCTUnwrap(runtime.lastHostView)
        hostView.keyDown(with: try makeKeyEvent(characters: "\r", keyCode: 36))

        XCTAssertTrue(receivedEvents.contains(.userSubmittedInput))
    }

    func test_navigation_key_does_not_emit_user_submitted_input_event() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let adapter = LibghosttyAdapter(runtime: runtime)
        var receivedEvents: [TerminalEvent] = []

        adapter.eventDidOccur = { receivedEvents.append($0) }

        _ = adapter.makeTerminalView()
        try adapter.startSession(using: TerminalSessionRequest())

        let hostView = try XCTUnwrap(runtime.lastHostView)
        hostView.keyDown(with: try makeKeyEvent(characters: "\u{F700}", keyCode: 126))

        XCTAssertFalse(receivedEvents.contains(.userSubmittedInput))
    }

    func test_prepare_session_start_uses_inherited_config_from_source_surface() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let sourceAdapter = LibghosttyAdapter(runtime: runtime)
        let splitAdapter = LibghosttyAdapter(runtime: runtime)
        let inheritedConfig = ghostty_surface_config_new()

        try sourceAdapter.startSession(using: TerminalSessionRequest())
        runtime.lastSurfaceController?.inheritedConfigContext = inheritedConfig.context

        splitAdapter.prepareSessionStart(from: sourceAdapter, context: .split)
        try splitAdapter.startSession(using: TerminalSessionRequest(configInheritanceSourcePaneID: PaneID("source")))

        XCTAssertEqual(runtime.makeSurfaceCallCount, 2)
        XCTAssertEqual(runtime.receivedConfigTemplates.count, 2)
        XCTAssertNil(runtime.receivedConfigTemplates[0])
        XCTAssertEqual(runtime.receivedConfigTemplates[1]?.context, inheritedConfig.context)
    }

    func test_prepare_session_start_requests_inherited_config_for_requested_context() throws {
        let runtime = LibghosttyRuntimeProviderSpy()
        let sourceAdapter = LibghosttyAdapter(runtime: runtime)
        let tabAdapter = LibghosttyAdapter(runtime: runtime)

        try sourceAdapter.startSession(using: TerminalSessionRequest())

        tabAdapter.prepareSessionStart(from: sourceAdapter, context: .tab)

        let surfaceController = try XCTUnwrap(runtime.lastSurfaceController)
        XCTAssertEqual(surfaceController.inheritedConfigRequests, [GHOSTTY_SURFACE_CONTEXT_TAB])
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

    func test_copy_action_payload_copies_command_finished_values() {
        let action = ghostty_action_s(
            tag: GHOSTTY_ACTION_COMMAND_FINISHED,
            action: ghostty_action_u(
                command_finished: ghostty_action_command_finished_s(
                    exit_code: 1,
                    duration: 250_000_000
                )
            )
        )

        let payload = copyLibghosttySurfaceActionPayload(from: action)

        XCTAssertEqual(payload, .commandFinished(exitCode: 1, durationNanoseconds: 250_000_000))
    }

    func test_copy_action_payload_copies_progress_report_values() {
        let action = ghostty_action_s(
            tag: GHOSTTY_ACTION_PROGRESS_REPORT,
            action: ghostty_action_u(
                progress_report: ghostty_action_progress_report_s(
                    state: GHOSTTY_PROGRESS_STATE_INDETERMINATE,
                    progress: -1
                )
            )
        )

        let payload = copyLibghosttySurfaceActionPayload(from: action)

        XCTAssertEqual(
            payload,
            .progressReport(TerminalProgressReport(state: .indeterminate, progress: nil))
        )
    }

    func test_copy_action_payload_copies_desktop_notification_values() {
        let duplicatedTitle = strdup("Codex")
        let duplicatedBody = strdup("Needs your input")
        defer {
            free(duplicatedTitle)
            free(duplicatedBody)
        }

        let action = ghostty_action_s(
            tag: GHOSTTY_ACTION_DESKTOP_NOTIFICATION,
            action: ghostty_action_u(
                desktop_notification: ghostty_action_desktop_notification_s(
                    title: duplicatedTitle,
                    body: duplicatedBody
                )
            )
        )

        let payload = copyLibghosttySurfaceActionPayload(from: action)

        XCTAssertEqual(
            payload,
            .desktopNotification(
                TerminalDesktopNotification(title: "Codex", body: "Needs your input")
            )
        )
    }

}

@MainActor
private final class LibghosttyRuntimeProviderSpy: LibghosttyRuntimeProviding {
    private(set) var makeSurfaceCallCount = 0
    private(set) weak var lastHostView: LibghosttyView?
    private(set) var lastMetadataHandler: ((TerminalMetadata) -> Void)?
    private(set) var lastEventHandler: ((TerminalEvent) -> Void)?
    private(set) var lastRequest: TerminalSessionRequest?
    private(set) var lastSurfaceController: LibghosttySurfaceControllerSpy?
    private(set) var receivedConfigTemplates: [ghostty_surface_config_s?] = []

    func makeSurface(
        for hostView: LibghosttyView,
        request: TerminalSessionRequest,
        configTemplate: ghostty_surface_config_s?,
        metadataDidChange: @escaping (TerminalMetadata) -> Void,
        eventDidOccur: @escaping (TerminalEvent) -> Void
    ) throws -> any LibghosttySurfaceControlling {
        makeSurfaceCallCount += 1
        lastHostView = hostView
        lastRequest = request
        lastMetadataHandler = metadataDidChange
        lastEventHandler = eventDidOccur
        receivedConfigTemplates.append(configTemplate)
        let surfaceController = LibghosttySurfaceControllerSpy()
        lastSurfaceController = surfaceController
        return surfaceController
    }
}

private final class LibghosttySurfaceControllerSpy: LibghosttySurfaceControlling {
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    private(set) var refreshCallCount = 0
    private(set) var focusValues: [Bool] = []
    private(set) var bindingActions: [String] = []
    private(set) var inheritedConfigRequests: [ghostty_surface_context_e] = []
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
        inheritedConfigRequests.append(context)
        guard let inheritedConfigContext else {
            return nil
        }

        var config = ghostty_surface_config_new()
        config.context = inheritedConfigContext
        return config
    }
}

private func makeKeyEvent(
    characters: String,
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try XCTUnwrap(
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    )
}
