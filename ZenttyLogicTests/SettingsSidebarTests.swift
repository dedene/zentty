import AppKit
import XCTest

@testable import Zentty

@MainActor
final class SettingsSidebarLayoutTests: AppKitTestCase {
    func test_default_layout_groups_match_expected_information_architecture() {
        let rows = SettingsSidebarViewController.flatten(SettingsSidebarLayout.groups)

        XCTAssertEqual(
            rows,
            [
                .section(.general),
                .section(.appearance),
                .section(.shortcuts),
                .section(.notifications),
                .section(.updatesPrivacy),
                .header("Workspace"),
                .section(.paneLayout),
                .section(.openWith),
                .section(.devServers),
                .section(.agents),
            ]
        )
    }

    func test_flatten_emits_header_then_its_sections_in_order() {
        let groups = [
            SettingsSidebarGroup(title: nil, sections: [.general]),
            SettingsSidebarGroup(title: "Group", sections: [.agents, .appearance]),
        ]

        XCTAssertEqual(
            SettingsSidebarViewController.flatten(groups),
            [.section(.general), .header("Group"), .section(.agents), .section(.appearance)]
        )
    }

    func test_flatten_includes_every_section_exactly_once() {
        let rows = SettingsSidebarViewController.flatten(SettingsSidebarLayout.groups)
        let sections = rows.compactMap { row -> SettingsSection? in
            if case let .section(section) = row { return section }
            return nil
        }

        XCTAssertEqual(Set(sections), Set(SettingsSection.allCases))
        XCTAssertEqual(sections.count, SettingsSection.allCases.count)
    }
}

@MainActor
final class SettingsSidebarSearchFilterTests: AppKitTestCase {
    private func sections(_ rows: [SettingsSidebarViewController.Row]) -> [SettingsSection] {
        rows.compactMap { row in
            if case let .section(section) = row { return section }
            return nil
        }
    }

    func test_empty_query_returns_full_layout() {
        let rows = SettingsSidebarViewController.filterRows(
            query: "   ",
            groups: SettingsSidebarLayout.groups
        )
        XCTAssertEqual(rows, SettingsSidebarViewController.flatten(SettingsSidebarLayout.groups))
    }

    func test_title_match_is_case_insensitive() {
        let rows = SettingsSidebarViewController.filterRows(
            query: "APPEAR",
            groups: SettingsSidebarLayout.groups
        )
        XCTAssertEqual(sections(rows), [.appearance])
    }

    func test_keyword_alias_matches_section() {
        let soundRows = SettingsSidebarViewController.filterRows(
            query: "sound",
            groups: SettingsSidebarLayout.groups
        )
        XCTAssertEqual(sections(soundRows), [.notifications])

        let crashRows = SettingsSidebarViewController.filterRows(
            query: "crash",
            groups: SettingsSidebarLayout.groups
        )
        XCTAssertEqual(sections(crashRows), [.updatesPrivacy])

        let ignoredPortRows = SettingsSidebarViewController.filterRows(
            query: "ignored",
            groups: SettingsSidebarLayout.groups
        )
        XCTAssertEqual(sections(ignoredPortRows), [.devServers])

        let menuBarRows = SettingsSidebarViewController.filterRows(
            query: "menu bar",
            groups: SettingsSidebarLayout.groups
        )
        XCTAssertEqual(sections(menuBarRows), [.agents])

        let worklaneRows = SettingsSidebarViewController.filterRows(
            query: "worklane",
            groups: SettingsSidebarLayout.groups
        )
        XCTAssertEqual(sections(worklaneRows), [.paneLayout])
    }

    func test_pane_layout_section_is_labeled_worklanes_and_panes() {
        XCTAssertEqual(SettingsSection.paneLayout.title, "Worklanes & Panes")
        XCTAssertEqual(SettingsSection.paneLayout.subtitle, "Worklane placement, labels, icons, opacity, and split behavior")
    }

    func test_filter_drops_group_headers_with_no_matches() {
        let rows = SettingsSidebarViewController.filterRows(
            query: "claude",
            groups: SettingsSidebarLayout.groups
        )
        // "claude" matches only Agents (in the Workspace group); the ungrouped
        // top items must be absent, leaving just the Workspace header + Agents.
        XCTAssertEqual(rows, [.header("Workspace"), .section(.agents)])
    }

    func test_no_match_returns_empty() {
        let rows = SettingsSidebarViewController.filterRows(
            query: "zzzznomatch",
            groups: SettingsSidebarLayout.groups
        )
        XCTAssertTrue(rows.isEmpty)
    }

    func test_external_selection_clears_filter_when_target_section_is_hidden() {
        let controller = SettingsSidebarViewController()
        controller.backwardCompatibleLoadViewIfNeeded()
        controller.searchField.stringValue = "sound"
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: controller.searchField
        ))
        XCTAssertEqual(controller.rows, [.section(.notifications)])

        controller.select(section: .appearance)

        XCTAssertEqual(controller.searchField.stringValue, "")
        XCTAssertEqual(controller.rows, SettingsSidebarViewController.flatten(SettingsSidebarLayout.groups))
        XCTAssertEqual(controller.tableView.selectedRow, 1)
    }
}

@MainActor
final class SettingsSidebarIconBadgeTests: AppKitTestCase {
    func test_image_has_requested_diameter() {
        let image = SettingsSidebarIconBadge.image(
            symbolName: "gearshape",
            color: .systemGray,
            diameter: 20
        )

        XCTAssertEqual(image.size.width, 20, accuracy: 0.5)
        XCTAssertEqual(image.size.height, 20, accuracy: 0.5)
    }

    func test_image_renders_for_every_section() {
        for section in SettingsSection.allCases {
            let image = SettingsSidebarIconBadge.image(
                symbolName: section.symbolName,
                color: section.badgeColor,
                diameter: 20
            )
            XCTAssertEqual(image.size.width, 20, accuracy: 0.5, "\(section.title) badge size")
        }
    }

    func test_cached_image_returns_the_same_instance_per_section_and_diameter() {
        let first = SettingsSidebarIconBadge.cachedImage(for: .general, diameter: 20)
        let second = SettingsSidebarIconBadge.cachedImage(for: .general, diameter: 20)

        XCTAssertTrue(first === second)
    }

    func test_badge_renders_white_symbol_over_colored_background() throws {
        // systemGray blends to ~0.6 brightness, so white symbol pixels (>0.9)
        // are clearly distinguishable from the gradient background.
        let image = SettingsSidebarIconBadge.image(
            symbolName: "gearshape.fill",
            color: .systemGray,
            diameter: 44
        )
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))

        var whitePixels = 0
        var coloredOpaquePixels = 0
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        for x in stride(from: 0, to: width, by: 2) {
            for y in stride(from: 0, to: height, by: 2) {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                guard pixel.alphaComponent > 0.9 else { continue }
                let brightness = (pixel.redComponent + pixel.greenComponent + pixel.blueComponent) / 3
                if brightness > 0.9 {
                    whitePixels += 1
                } else if brightness > 0.2 {
                    coloredOpaquePixels += 1
                }
            }
        }

        XCTAssertGreaterThan(whitePixels, 0, "Expected white SF Symbol pixels in the badge")
        XCTAssertGreaterThan(
            coloredOpaquePixels,
            whitePixels,
            "Expected the colored badge background to dominate the symbol"
        )
    }
}

@MainActor
final class SettingsContentHeaderViewTests: AppKitTestCase {
    func test_configure_sets_title_and_subtitle_for_section() {
        let header = SettingsContentHeaderView()

        header.configure(with: .updatesPrivacy)

        XCTAssertEqual(header.titleForTesting, "Updates & Privacy")
        XCTAssertEqual(header.subtitleForTesting, SettingsSection.updatesPrivacy.subtitle)
        XCTAssertFalse(header.subtitleForTesting.isEmpty)
    }

    func test_every_section_has_a_nonempty_subtitle() {
        for section in SettingsSection.allCases {
            XCTAssertFalse(section.subtitle.isEmpty, "\(section.title) is missing a subtitle")
        }
    }
}

@MainActor
final class SettingsSidebarRowViewTests: AppKitTestCase {
    func test_sidebar_table_uses_full_width_style() {
        let controller = SettingsSidebarViewController()

        controller.backwardCompatibleLoadViewIfNeeded()

        XCTAssertEqual(controller.tableView.style, .fullWidth)
    }

    func test_sidebar_row_tracking_update_preserves_external_tracking_areas() {
        let row = SettingsSidebarTableRowView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        let externalTrackingArea = NSTrackingArea(
            rect: row.bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: row
        )
        row.addTrackingArea(externalTrackingArea)

        row.updateTrackingAreas()
        row.updateTrackingAreas()

        XCTAssertTrue(row.trackingAreas.contains { $0 === externalTrackingArea })
    }

    func test_configure_sets_title_and_badge_for_section() {
        let row = SettingsSidebarRowView()

        row.configure(with: .notifications)

        XCTAssertEqual(row.titleForTesting, "Notifications")
        XCTAssertNotNil(row.badgeImageForTesting)
    }

    func test_reconfigure_updates_title_to_new_section() {
        let row = SettingsSidebarRowView()

        row.configure(with: .general)
        XCTAssertEqual(row.titleForTesting, "General")

        row.configure(with: .updatesPrivacy)
        XCTAssertEqual(row.titleForTesting, "Updates & Privacy")
    }
}
