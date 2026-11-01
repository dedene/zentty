import AppKit
import XCTest
@testable import Zentty

final class AgentHistoryPanelLayoutTests: XCTestCase {
    private func layout(
        width: CGFloat,
        height: CGFloat = 900,
        origin: NSPoint = .zero,
        mode: AgentHistoryPanelLayout.Mode = .results
    ) -> AgentHistoryPanelLayout {
        AgentHistoryPanelLayout.resolve(
            windowFrame: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            mode: mode
        )
    }

    func test_wide_window_gets_full_size_panel_with_wide_list() {
        let result = layout(width: 1440, height: 900)
        XCTAssertEqual(result.frame.size, NSSize(width: 1010, height: 580))
        XCTAssertEqual(result.listWidth, 430)
        XCTAssertTrue(result.showsPreview)
        XCTAssertFalse(result.isCompact)
    }

    func test_window_of_950_shrinks_to_90_percent_with_narrow_list() {
        let result = layout(width: 950)
        XCTAssertEqual(result.frame.width, 855)
        XCTAssertEqual(result.listWidth, 380)
        XCTAssertTrue(result.showsPreview)
    }

    func test_window_of_800_keeps_760_minimum() {
        let result = layout(width: 800)
        XCTAssertEqual(result.frame.width, 760)
        XCTAssertEqual(result.listWidth, 380)
        XCTAssertTrue(result.showsPreview)
    }

    func test_window_of_700_is_compact_without_preview() {
        let result = layout(width: 700)
        XCTAssertEqual(result.frame.width, 630)
        XCTAssertEqual(result.listWidth, 630)
        XCTAssertFalse(result.showsPreview)
        XCTAssertTrue(result.isCompact)
        XCTAssertEqual(layout(width: 380).frame.width, 360)
    }

    func test_short_window_clamps_height() {
        XCTAssertEqual(layout(width: 1440, height: 400).frame.height, 320)
        XCTAssertEqual(layout(width: 1440, height: 700).frame.height, 509)
    }

    func test_origin_is_centered_quarter_from_top_and_integral() {
        let result = layout(width: 1441, height: 901, origin: NSPoint(x: 100.5, y: 50.25))
        let frame = result.frame
        XCTAssertEqual(frame.origin.x, frame.origin.x.rounded())
        XCTAssertEqual(frame.origin.y, frame.origin.y.rounded())
        XCTAssertEqual(frame.midX, 100.5 + 1441 / 2, accuracy: 1)
        let windowMaxY: CGFloat = 50.25 + 901
        XCTAssertEqual(windowMaxY - frame.maxY, 0.25 * 901, accuracy: 1)
    }

    func test_consent_card_is_640_wide_and_fits_its_content() {
        let result = layout(width: 1440, height: 900, mode: .consent(fittingHeight: 470.3))
        XCTAssertEqual(result.frame.width, 640)
        XCTAssertEqual(result.frame.height, 471)
        XCTAssertFalse(result.showsPreview)

        let narrow = layout(width: 600, height: 900, mode: .consent(fittingHeight: 470))
        XCTAssertEqual(narrow.frame.width, 568)

        let tall = layout(width: 1440, height: 600, mode: .consent(fittingHeight: 900))
        XCTAssertEqual(tall.frame.height, 434)
    }
}
