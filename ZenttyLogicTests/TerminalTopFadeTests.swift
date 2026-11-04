import AppKit
import XCTest
@testable import Zentty

@MainActor
final class TerminalTopFadeTests: AppKitTestCase {
    func test_host_pushes_12pt_fade_to_conforming_terminal_view() {
        let terminalView = TopFadeSpyTerminalView()
        let adapter = TopFadeTerminalAdapterSpy(terminalView: terminalView)

        _ = TerminalPaneHostView(adapter: adapter)

        XCTAssertEqual(terminalView.topFadeHeight, 12)
        XCTAssertEqual(TerminalPaneHostView.topFadeHeight, 12)
    }

    func test_non_conforming_terminal_view_is_left_alone() {
        let adapter = TopFadeTerminalAdapterSpy(terminalView: NSView())

        let host = TerminalPaneHostView(adapter: adapter)

        XCTAssertNil(host.layer?.mask)
    }
}

@MainActor
private final class TopFadeSpyTerminalView: NSView, TerminalTopFadeConfiguring {
    var topFadeHeight: CGFloat = 0
}

@MainActor
private final class TopFadeTerminalAdapterSpy: TerminalAdapter {
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    private let terminalView: NSView

    init(terminalView: NSView) {
        self.terminalView = terminalView
    }

    func makeTerminalView() -> NSView { terminalView }
    func startSession(using request: TerminalSessionRequest) throws {}
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}
    func sendText(_ text: String) {}
    func close() {}
}
