import CoreGraphics
import XCTest
@testable import Zentty

final class PaneBorderActionsLayoutTests: XCTestCase {
    func test_tile_actions_are_float_and_close() {
        XCTAssertEqual(PaneBorderActionsLayout.actions(for: .tile), [.float, .close])
    }

    func test_float_actions_are_pip_minimize_dock_close() {
        XCTAssertEqual(PaneBorderActionsLayout.actions(for: .float), [.pip, .minimize, .dock, .close])
    }

    func test_pip_actions_are_restore_minimize_close() {
        XCTAssertEqual(PaneBorderActionsLayout.actions(for: .pip), [.restore, .minimize, .close])
    }

    func test_tile_visible_only_on_hover_or_focus() {
        XCTAssertFalse(PaneBorderActionsLayout.isVisible(kind: .tile, isHovered: false, isFocused: false))
        XCTAssertTrue(PaneBorderActionsLayout.isVisible(kind: .tile, isHovered: true, isFocused: false))
        XCTAssertTrue(PaneBorderActionsLayout.isVisible(kind: .tile, isHovered: false, isFocused: true))
    }

    func test_float_always_visible() {
        XCTAssertTrue(PaneBorderActionsLayout.isVisible(kind: .float, isHovered: false, isFocused: false))
    }

    func test_pip_visible_only_on_hover() {
        XCTAssertFalse(PaneBorderActionsLayout.isVisible(kind: .pip, isHovered: false, isFocused: true))
        XCTAssertTrue(PaneBorderActionsLayout.isVisible(kind: .pip, isHovered: true, isFocused: false))
    }

    func test_size_for_four_buttons() {
        XCTAssertEqual(
            PaneBorderActionsLayout.size(for: PaneBorderActionsLayout.actions(for: .float)),
            CGSize(width: 86, height: 16)
        )
        XCTAssertEqual(PaneBorderActionsLayout.size(for: []), .zero)
    }

    func test_frame_right_aligned_and_centred_on_top_border() {
        let size = CGSize(width: 86, height: 16)
        let frame = PaneBorderActionsLayout.frame(
            size: size,
            borderFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
            borderInset: 1,
            strokeWidth: 1
        )

        XCTAssertEqual(frame.maxX, 377, accuracy: 0.001)
        XCTAssertEqual(frame.midY, 299.5, accuracy: 0.001)
        XCTAssertEqual(frame.size, size)
    }

    func test_every_action_names_a_symbol_and_a_label() {
        for action in PaneBorderAction.allCases {
            XCTAssertFalse(action.symbolName.isEmpty)
            XCTAssertFalse(action.accessibilityLabel.isEmpty)
        }
        XCTAssertEqual(PaneBorderAction.float.commandID, .toggleFloat)
        XCTAssertEqual(PaneBorderAction.dock.commandID, .toggleFloat)
        XCTAssertEqual(PaneBorderAction.close.commandID, .closeFocusedPane)
    }
}
