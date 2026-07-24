import AppKit
import GhosttyKit
import XCTest
@testable import Zentty

@MainActor
final class LibghosttyViewIMETests: AppKitTestCase {
    /// Caret as Ghostty reports it: points, measured from the surface's top-left.
    private static let caret = CGRect(x: 120, y: 208, width: 16, height: 16)
    private static let surfaceSize = CGSize(width: 800, height: 600)

    private var view: LibghosttyView!
    private var surface: IMESurfaceSpy!
    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        view = LibghosttyView(frame: NSRect(origin: .zero, size: Self.surfaceSize))
        surface = IMESurfaceSpy()
        surface.imeRectValue = Self.caret
        view.bind(surfaceController: surface)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.surfaceSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        ).prepareForAppKitTesting()
        window.contentView?.addSubview(view)
    }

    override func tearDown() {
        // End any composition these tests started, symmetric with setMarkedText.
        view.unmarkText()
        window.close()
        window = nil
        view = nil
        surface = nil
        super.tearDown()
    }

    private func beginComposing(_ text: String = "ㄘ") {
        view.setMarkedText(
            text,
            selectedRange: NSRange(location: 0, length: text.utf16.count),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    private func composingRect() -> NSRect {
        view.firstRect(forCharacterRange: view.markedRange(), actualRange: nil)
    }

    private var surfaceRectOnScreen: NSRect {
        window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    // `firstRect(forCharacterRange:)` is what positions the input method's candidate
    // window. Handing back the whole surface pins that window to the surface edge,
    // where it lands off-screen instead of next to the caret.
    func test_firstRect_while_composing_is_caret_sized_not_surface_sized() {
        beginComposing()
        XCTAssertTrue(view.hasMarkedText())

        let rect = composingRect()

        XCTAssertEqual(rect.width, Self.caret.width, accuracy: 0.5)
        XCTAssertEqual(rect.height, Self.caret.height, accuracy: 0.5)
        XCTAssertLessThan(rect.height, Self.surfaceSize.height)
        XCTAssertLessThan(rect.width, Self.surfaceSize.width)
    }

    // Ghostty measures the caret from the top of the surface while AppKit measures from
    // the bottom, so this pins the flip — a sign error here puts the candidate window
    // an entire surface-height away from the caret.
    func test_firstRect_anchors_caret_measured_from_surface_top() {
        beginComposing()

        let rect = composingRect()
        let surfaceOnScreen = surfaceRectOnScreen

        XCTAssertEqual(rect.minX - surfaceOnScreen.minX, Self.caret.minX, accuracy: 0.5)
        XCTAssertEqual(surfaceOnScreen.maxY - rect.minY, Self.caret.minY, accuracy: 0.5)
    }

    func test_firstRect_without_a_composition_target_is_empty() {
        surface.imeRectValue = nil

        XCTAssertEqual(composingRect(), .zero)
    }

    // The terminal renders the composition inline at the caret, so it has to be told
    // what is being composed — otherwise nothing appears while typing.
    func test_composing_forwards_preedit_to_terminal() {
        beginComposing("ㄘㄜ")

        XCTAssertEqual(surface.preeditUpdates, ["ㄘㄜ"])
    }

    func test_unmarking_clears_preedit() {
        beginComposing()
        view.unmarkText()

        XCTAssertEqual(surface.preeditUpdates, ["ㄘ", ""])
    }

    func test_committing_text_clears_preedit() {
        beginComposing()
        view.insertText("測", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(surface.preeditUpdates, ["ㄘ", ""])
        XCTAssertFalse(view.hasMarkedText())
    }
}

private final class IMESurfaceSpy: LibghosttySurfaceControlling {
    var hasScrollback = false
    var cellWidth: CGFloat = 8
    var cellHeight: CGFloat = 16
    var searchDidChange: ((TerminalSearchEvent) -> Void)?
    var imeRectValue: CGRect?
    private(set) var preeditUpdates: [String] = []

    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?) {}
    func setFocused(_ isFocused: Bool) {}
    func setOcclusionVisible(_ isVisible: Bool) {}
    func refresh() {}
    func sendKey(event: NSEvent, action: TerminalKeyAction, text: String?, composing: Bool) -> Bool { true }
    func sendMouseScroll(x: Double, y: Double, precision: Bool, momentum: NSEvent.Phase) {}
    func sendMousePosition(_ position: CGPoint, modifiers: NSEvent.ModifierFlags) {}
    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool { false }
    func sendText(_ text: String) {}
    func setPreedit(_ text: String) {
        preeditUpdates.append(text)
    }
    func imeRect() -> CGRect? { imeRectValue }
    func submitReturn() {}
    func performBindingAction(_ action: String) -> Bool { true }
    func hasSelection() -> Bool { false }
    func close() {}
    func inheritedConfig(for context: ghostty_surface_context_e) -> ghostty_surface_config_s? { nil }
}
