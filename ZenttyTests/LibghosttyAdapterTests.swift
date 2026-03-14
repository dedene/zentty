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

    func makeSurface(
        for hostView: LibghosttyView,
        request: TerminalSessionRequest,
        metadataDidChange: @escaping (TerminalMetadata) -> Void
    ) throws -> any LibghosttySurfaceControlling {
        makeSurfaceCallCount += 1
        lastHostView = hostView
        lastRequest = request
        lastMetadataHandler = metadataDidChange
        return LibghosttySurfaceControllerSpy()
    }
}

private final class LibghosttySurfaceControllerSpy: LibghosttySurfaceControlling {
    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?) {}
    func setFocused(_ isFocused: Bool) {}
    func refresh() {}
    func sendKey(event: NSEvent, action: TerminalKeyAction, text: String?, composing: Bool) -> Bool { true }
    func sendText(_ text: String) {}
}
