import AppKit
import XCTest
@testable import Zentty

@MainActor
final class WorklaneColorMenuItemViewTests: AppKitTestCase {
    func test_view_sizes_to_fit_grid_plus_separator_plus_reset_row() {
        let view = WorklaneColorMenuItemView(current: nil) { _ in }
        XCTAssertGreaterThan(view.frame.width, 0)
        XCTAssertGreaterThan(view.frame.height, 0)
    }

    func test_a11y_is_radio_group_with_13_children() {
        let view = WorklaneColorMenuItemView(current: nil) { _ in }
        XCTAssertEqual(view.accessibilityRole(), .radioGroup)
        let children = view.accessibilityChildren() ?? []
        XCTAssertEqual(children.count, WorklaneColor.allCases.count + 1)
    }

    func test_current_color_marks_matching_swatch() {
        let view = WorklaneColorMenuItemView(current: .blue) { _ in }
        let children = view.accessibilityChildren() as? [NSObject] ?? []
        let swatches = children.compactMap { $0 as? WorklaneColorSwatchView }
        let currentSwatch = swatches.first(where: { $0.color == .blue })
        XCTAssertNotNil(currentSwatch)
        XCTAssertTrue(currentSwatch?.isCurrent ?? false)
        XCTAssertEqual(swatches.filter { $0.isCurrent }.count, 1)
    }

    func test_clicking_swatch_invokes_onPick_with_color() {
        var picked: WorklaneColor? = nil
        var pickedCalled = false
        let view = WorklaneColorMenuItemView(current: .red) { color in
            picked = color
            pickedCalled = true
        }
        let swatches = view.accessibilityChildren()?.compactMap { $0 as? WorklaneColorSwatchView } ?? []
        let orangeSwatch = try? XCTUnwrap(swatches.first(where: { $0.color == .orange }))
        orangeSwatch?.onClick?(.orange)
        XCTAssertTrue(pickedCalled)
        XCTAssertEqual(picked, .orange)
    }

    func test_clicking_reset_row_invokes_onPick_with_nil() {
        var picked: WorklaneColor? = .red
        var calledWithNil = false
        let view = WorklaneColorMenuItemView(current: .red) { color in
            picked = color
            if color == nil { calledWithNil = true }
        }
        let resetRow = view.accessibilityChildren()?.compactMap { $0 as? WorklaneColorResetRowView }.first
        XCTAssertNotNil(resetRow)
        resetRow?.onClick?()
        XCTAssertTrue(calledWithNil)
        XCTAssertNil(picked)
    }

    func test_each_swatch_has_color_name_as_a11y_label_and_tooltip() {
        let view = WorklaneColorMenuItemView(current: nil) { _ in }
        let swatches = view.accessibilityChildren()?.compactMap { $0 as? WorklaneColorSwatchView } ?? []
        for swatch in swatches {
            XCTAssertEqual(swatch.accessibilityLabel(), swatch.color.localizedName)
            XCTAssertEqual(swatch.toolTip, swatch.color.localizedName)
            XCTAssertEqual(swatch.accessibilityRole(), .radioButton)
        }
    }
}
