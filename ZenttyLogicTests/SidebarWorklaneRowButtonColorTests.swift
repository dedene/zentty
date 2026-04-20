import AppKit
import XCTest
@testable import Zentty

@MainActor
final class SidebarWorklaneRowButtonColorTests: AppKitTestCase {
    func test_no_color_leaves_tint_layer_clear() {
        let row = makeRow()
        row.configure(with: makeSummary(color: nil, isActive: false), theme: ZenttyTheme.fallback(for: nil), animated: false)
        let cg = row.tintLayerBackgroundColorForTesting ?? NSColor.clear.cgColor
        XCTAssertEqual(cg.alpha, 0, accuracy: 0.001)
    }

    func test_inactive_colored_row_uses_inactive_alpha() {
        let row = makeRow()
        row.configure(with: makeSummary(color: .red, isActive: false), theme: ZenttyTheme.fallback(for: nil), animated: false)
        let alpha = row.tintLayerBackgroundColorForTesting?.alpha ?? -1
        XCTAssertEqual(alpha, WorklaneColor.Alpha.inactive, accuracy: 0.001)
    }

    func test_hovered_colored_row_uses_hover_alpha() {
        let row = makeRow()
        row.configure(with: makeSummary(color: .blue, isActive: false), theme: ZenttyTheme.fallback(for: nil), animated: false)
        row.setHoveredForTesting(true)
        let alpha = row.tintLayerBackgroundColorForTesting?.alpha ?? -1
        XCTAssertEqual(alpha, WorklaneColor.Alpha.hover, accuracy: 0.001)
    }

    func test_active_colored_row_uses_active_alpha() {
        let row = makeRow()
        row.configure(with: makeSummary(color: .green, isActive: true), theme: ZenttyTheme.fallback(for: nil), animated: false)
        let alpha = row.tintLayerBackgroundColorForTesting?.alpha ?? -1
        XCTAssertEqual(alpha, WorklaneColor.Alpha.active, accuracy: 0.001)
    }

    func test_clearing_color_resets_tint() {
        let row = makeRow()
        let theme = ZenttyTheme.fallback(for: nil)
        row.configure(with: makeSummary(color: .purple, isActive: false), theme: theme, animated: false)
        XCTAssertGreaterThan(row.tintLayerBackgroundColorForTesting?.alpha ?? 0, 0)

        row.configure(with: makeSummary(color: nil, isActive: false), theme: theme, animated: false)
        XCTAssertEqual(row.tintLayerBackgroundColorForTesting?.alpha ?? -1, 0, accuracy: 0.001)
    }

    private func makeRow(width: CGFloat = 280, height: CGFloat = 72) -> SidebarWorklaneRowButton {
        let row = SidebarWorklaneRowButton(
            worklaneID: WorklaneID("worklane-main"),
            reducedMotionProvider: { false }
        )
        row.frame = NSRect(x: 0, y: 0, width: width, height: height)
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    private func makeSummary(color: WorklaneColor?, isActive: Bool) -> WorklaneSidebarSummary {
        WorklaneSidebarSummary(
            worklaneID: WorklaneID("worklane-main"),
            badgeText: "1",
            primaryText: "project",
            isActive: isActive,
            color: color
        )
    }
}
