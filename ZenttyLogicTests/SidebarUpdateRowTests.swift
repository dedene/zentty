import AppKit
import XCTest
@testable import Zentty

@MainActor
final class SidebarUpdateRowTests: AppKitTestCase {
    func test_sidebar_view_keeps_bottom_update_row_outside_scroll_view() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.render(
            summaries: [
                WorklaneSidebarSummary(
                    worklaneID: WorklaneID("worklane-main"),
                    badgeText: "1",
                    primaryText: "~",
                    isActive: true
                )
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )

        sidebarView.layoutSubtreeIfNeeded()

        let updateRow = try XCTUnwrap(sidebarView.firstDescendant(named: "SidebarUpdateAvailableRowView"))
        let scrollView = try XCTUnwrap(sidebarView.firstDescendant(ofType: NSScrollView.self))

        XCTAssertFalse(scrollView.containsDescendant(updateRow))
    }

    func test_sidebar_view_hides_update_row_by_default() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.layoutSubtreeIfNeeded()

        let updateRow = try XCTUnwrap(sidebarView.firstDescendant(named: "SidebarUpdateAvailableRowView"))

        XCTAssertTrue(updateRow.isHidden)
        XCTAssertEqual(updateRow.frame.height, 0, accuracy: 0.001)
    }

    func test_sidebar_view_shows_update_row_when_update_is_available() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.setUpdateAvailable(true, animated: false)
        sidebarView.layoutSubtreeIfNeeded()

        let updateRow = try XCTUnwrap(sidebarView.firstDescendant(named: "SidebarUpdateAvailableRowView"))
        let updateLabel = try XCTUnwrap(updateRow.firstDescendantLabel(stringValue: "Update available"))

        XCTAssertFalse(updateRow.isHidden)
        XCTAssertEqual(updateRow.frame.height, 28, accuracy: 0.001)
        XCTAssertGreaterThan(updateLabel.frame.width, 0)
    }

    func test_sidebar_view_update_row_uses_shell_derived_bottom_radius() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.setUpdateAvailable(true, animated: false)
        sidebarView.layoutSubtreeIfNeeded()

        let updateRow = try XCTUnwrap(sidebarView.firstDescendant(named: "SidebarUpdateAvailableRowView"))
        let expectedRadius = ChromeGeometry.innerRadius(
            outerRadius: ShellMetrics.sidebarRadius,
            inset: ShellMetrics.sidebarContentInset
        )

        XCTAssertEqual(updateRow.layer?.cornerRadius ?? 0, expectedRadius, accuracy: 0.001)
    }

    func test_sidebar_view_update_row_uses_compact_height() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.setUpdateAvailable(true, animated: false)
        sidebarView.layoutSubtreeIfNeeded()

        let updateRow = try XCTUnwrap(sidebarView.firstDescendant(named: "SidebarUpdateAvailableRowView"))

        XCTAssertEqual(updateRow.frame.height, 28, accuracy: 0.001)
    }

    func test_sidebar_view_update_row_centers_its_label() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.setUpdateAvailable(true, animated: false)
        sidebarView.layoutSubtreeIfNeeded()

        let updateRow = try XCTUnwrap(sidebarView.firstDescendant(named: "SidebarUpdateAvailableRowView"))
        let updateLabel = try XCTUnwrap(updateRow.firstDescendantLabel(stringValue: "Update available"))

        let rowFrame = sidebarView.convert(updateRow.bounds, from: updateRow)
        let labelFrame = sidebarView.convert(updateLabel.bounds, from: updateLabel)

        XCTAssertEqual(labelFrame.midX, rowFrame.midX, accuracy: 12)
    }

    func test_sidebar_view_update_row_rounds_all_four_corners() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 500))
        sidebarView.setUpdateAvailable(true, animated: false)
        sidebarView.layoutSubtreeIfNeeded()

        let updateRow = try XCTUnwrap(sidebarView.firstDescendant(named: "SidebarUpdateAvailableRowView"))
        let expectedCorners: CACornerMask = [
            .layerMinXMinYCorner,
            .layerMaxXMinYCorner,
            .layerMinXMaxYCorner,
            .layerMaxXMaxYCorner,
        ]

        XCTAssertEqual(updateRow.layer?.maskedCorners, expectedCorners)
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T {
                return match
            }
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }
        return nil
    }

    func firstDescendant(named className: String) -> NSView? {
        for subview in subviews {
            if String(describing: type(of: subview)) == className {
                return subview
            }
            if let match = subview.firstDescendant(named: className) {
                return match
            }
        }
        return nil
    }

    func firstDescendantLabel(stringValue: String) -> NSTextField? {
        for subview in subviews {
            if let label = subview as? NSTextField, label.stringValue == stringValue {
                return label
            }
            if let match = subview.firstDescendantLabel(stringValue: stringValue) {
                return match
            }
        }
        return nil
    }

    func containsDescendant(_ candidate: NSView) -> Bool {
        if subviews.contains(where: { $0 === candidate }) {
            return true
        }
        return subviews.contains { $0.containsDescendant(candidate) }
    }
}
