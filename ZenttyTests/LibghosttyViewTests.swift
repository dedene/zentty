import AppKit
import XCTest
@testable import Zentty

@MainActor
final class LibghosttyViewTests: XCTestCase {
    func test_layout_updates_surface_viewport_using_view_bounds() throws {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        view.bind(surfaceController: surface)

        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(surface.viewportUpdates.count, 1)
        let update = try XCTUnwrap(surface.viewportUpdates.last)
        let expectedBackingSize = view.convertToBacking(view.bounds).size
        XCTAssertEqual(update.size.width, expectedBackingSize.width, accuracy: 0.001)
        XCTAssertEqual(update.size.height, expectedBackingSize.height, accuracy: 0.001)
        XCTAssertGreaterThan(update.scale, 0)
    }

    func test_focus_changes_are_forwarded_to_surface() {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertTrue(view.resignFirstResponder())

        XCTAssertEqual(surface.focusUpdates, [true, false])
    }

    func test_key_down_forwards_text_to_surface() throws {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))

        view.keyDown(with: event)

        XCTAssertEqual(surface.keyEvents.count, 1)
        XCTAssertEqual(surface.keyEvents[0].text, "a")
        XCTAssertEqual(surface.keyEvents[0].action, .press)
    }

    func test_key_up_forwards_release_to_surface() throws {
        let view = LibghosttyView()
        let surface = LibghosttySurfaceViewportSpy()
        view.bind(surfaceController: surface)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0
        ))

        view.keyUp(with: event)

        XCTAssertEqual(surface.keyEvents.count, 1)
        XCTAssertEqual(surface.keyEvents[0].action, .release)
    }
}

private final class LibghosttySurfaceViewportSpy: LibghosttySurfaceControlling {
    struct ViewportUpdate: Equatable {
        let size: CGSize
        let scale: CGFloat
        let displayID: UInt32?
    }

    struct KeyEventRecord: Equatable {
        let action: TerminalKeyAction
        let text: String?
        let composing: Bool
    }

    private(set) var viewportUpdates: [ViewportUpdate] = []
    private(set) var focusUpdates: [Bool] = []
    private(set) var keyEvents: [KeyEventRecord] = []

    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?) {
        viewportUpdates.append(.init(size: size, scale: scale, displayID: displayID))
    }

    func setFocused(_ isFocused: Bool) {
        focusUpdates.append(isFocused)
    }

    func refresh() {}

    func sendKey(event: NSEvent, action: TerminalKeyAction, text: String?, composing: Bool) -> Bool {
        keyEvents.append(.init(action: action, text: text, composing: composing))
        return true
    }

    func sendText(_ text: String) {}
}
