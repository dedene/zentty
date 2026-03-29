import AppKit
import GhosttyKit
import XCTest
@testable import Zentty

@MainActor
final class LibghosttyViewDragDropTests: XCTestCase {
    private var view: LibghosttyView!
    private var surface: SurfaceTextSpy!

    override func setUp() {
        super.setUp()
        view = LibghosttyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        surface = SurfaceTextSpy()
        view.bind(surfaceController: surface)
    }

    override func tearDown() {
        view = nil
        surface = nil
        super.tearDown()
    }

    // MARK: - draggingEntered

    func test_dragging_entered_accepts_file_url_type() {
        let info = StubDraggingInfo(types: [.fileURL])
        XCTAssertEqual(view.draggingEntered(info), .copy)
    }

    func test_dragging_entered_accepts_string_type() {
        let info = StubDraggingInfo(types: [.string])
        XCTAssertEqual(view.draggingEntered(info), .copy)
    }

    func test_dragging_entered_accepts_url_type() {
        let info = StubDraggingInfo(types: [.URL])
        XCTAssertEqual(view.draggingEntered(info), .copy)
    }

    func test_dragging_entered_rejects_unknown_type() {
        let info = StubDraggingInfo(types: [.color])
        XCTAssertEqual(view.draggingEntered(info), NSDragOperation())
    }

    // MARK: - performDragOperation

    func test_perform_drag_inserts_escaped_file_path() {
        let pasteboard = makeTestPasteboard()
        pasteboard.declareTypes([.fileURL], owner: nil)
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/my folder/file (1).txt") as NSURL])

        let info = StubDraggingInfo(pasteboard: pasteboard)
        XCTAssertTrue(view.performDragOperation(info))
        XCTAssertEqual(surface.sentTexts.last, "/tmp/my\\ folder/file\\ \\(1\\).txt")
    }

    func test_perform_drag_inserts_multiple_file_paths_space_separated() {
        let pasteboard = makeTestPasteboard()
        pasteboard.declareTypes([.fileURL], owner: nil)
        pasteboard.writeObjects([
            URL(fileURLWithPath: "/tmp/a b") as NSURL,
            URL(fileURLWithPath: "/tmp/c d") as NSURL,
        ])

        let info = StubDraggingInfo(pasteboard: pasteboard)
        XCTAssertTrue(view.performDragOperation(info))
        XCTAssertEqual(surface.sentTexts.last, "/tmp/a\\ b /tmp/c\\ d")
    }

    func test_perform_drag_inserts_plain_string_without_escaping() {
        let pasteboard = makeTestPasteboard()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("echo hello world", forType: .string)

        let info = StubDraggingInfo(pasteboard: pasteboard)
        XCTAssertTrue(view.performDragOperation(info))
        XCTAssertEqual(surface.sentTexts.last, "echo hello world")
    }

    func test_perform_drag_returns_false_for_empty_pasteboard() {
        let pasteboard = makeTestPasteboard()
        pasteboard.declareTypes([.color], owner: nil)

        let info = StubDraggingInfo(pasteboard: pasteboard)
        XCTAssertFalse(view.performDragOperation(info))
        XCTAssertTrue(surface.sentTexts.isEmpty)
    }

    // MARK: - Helpers

    private func makeTestPasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("test-\(UUID().uuidString)"))
    }

}

// MARK: - Test Doubles

private final class SurfaceTextSpy: LibghosttySurfaceControlling {
    var hasScrollback = false
    var cellWidth: CGFloat = 8
    var cellHeight: CGFloat = 16
    private(set) var sentTexts: [String] = []

    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?) {}
    func setFocused(_ isFocused: Bool) {}
    func refresh() {}
    func sendKey(event: NSEvent, action: TerminalKeyAction, text: String?, composing: Bool) -> Bool { true }
    func sendMouseScroll(x: Double, y: Double, precision: Bool, momentum: NSEvent.Phase) {}
    func sendMousePosition(_ position: CGPoint, modifiers: NSEvent.ModifierFlags) {}
    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        modifiers: NSEvent.ModifierFlags
    ) {}
    func sendText(_ text: String) { sentTexts.append(text) }
    func performBindingAction(_ action: String) -> Bool { true }
    func hasSelection() -> Bool { false }
    func close() {}
    func inheritedConfig(for context: ghostty_surface_context_e) -> ghostty_surface_config_s? { nil }
}

private final class StubDraggingInfo: NSObject, NSDraggingInfo, @unchecked Sendable {
    nonisolated(unsafe) let draggingPasteboard: NSPasteboard
    nonisolated(unsafe) var draggingDestinationWindow: NSWindow? { nil }
    nonisolated(unsafe) var draggingSequenceNumber: Int { 0 }
    nonisolated(unsafe) var draggingSource: Any? { nil }
    nonisolated(unsafe) var draggingSourceOperationMask: NSDragOperation { .copy }
    nonisolated(unsafe) var draggingLocation: NSPoint { .zero }
    nonisolated(unsafe) var draggedImageLocation: NSPoint { .zero }
    nonisolated(unsafe) var draggedImage: NSImage? { nil }
    nonisolated(unsafe) var draggingFormation: NSDraggingFormation { get { .default } set {} }
    nonisolated(unsafe) var animatesToDestination: Bool { get { false } set {} }
    nonisolated(unsafe) var numberOfValidItemsForDrop: Int { get { 0 } set {} }
    nonisolated(unsafe) var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    @MainActor
    init(types: [NSPasteboard.PasteboardType]) {
        let pb = NSPasteboard(name: .init("stub-\(UUID().uuidString)"))
        pb.declareTypes(types, owner: nil)
        self.draggingPasteboard = pb
        super.init()
    }

    @MainActor
    init(pasteboard: NSPasteboard) {
        self.draggingPasteboard = pasteboard
        super.init()
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}
