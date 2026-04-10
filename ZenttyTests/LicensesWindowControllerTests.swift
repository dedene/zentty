import AppKit
import XCTest
@testable import Zentty

@MainActor
final class LicensesWindowControllerTests: XCTestCase {
    func test_window_shows_catalog_entries_and_updates_detail_when_selection_changes() throws {
        let catalog = ThirdPartyLicenseCatalog(entries: [
            ThirdPartyLicenseEntry(
                id: "ghostty",
                displayName: "Ghostty",
                version: "e75f895",
                licenseName: "MIT License",
                spdxID: "MIT",
                sourceURLString: "https://github.com/ghostty-org/ghostty",
                homepageURLString: nil,
                fullText: "Permission is hereby granted..."
            ),
            ThirdPartyLicenseEntry(
                id: "sparkle",
                displayName: "Sparkle",
                version: "2.9.1",
                licenseName: "Sparkle License",
                spdxID: nil,
                sourceURLString: "https://github.com/sparkle-project/Sparkle",
                homepageURLString: "https://sparkle-project.org",
                fullText: "Sparkle license text"
            ),
        ])
        let controller = LicensesWindowController(catalog: catalog)
        addTeardownBlock { controller.window?.close() }

        controller.show(sender: nil)
        waitForLayout()

        XCTAssertEqual(controller.window?.title, "Third-Party Licenses")
        XCTAssertEqual(controller.entryCountForTesting, 2)
        XCTAssertEqual(controller.selectedEntryDisplayNameForTesting, "Ghostty")
        XCTAssertEqual(controller.selectedEntryLicenseNameForTesting, "MIT License")
        XCTAssertTrue(controller.detailTextForTesting.contains("Permission is hereby granted"))

        controller.selectEntryForTesting(id: "sparkle")
        waitForLayout("sparkle selected")

        XCTAssertEqual(controller.selectedEntryDisplayNameForTesting, "Sparkle")
        XCTAssertEqual(controller.selectedEntryLicenseNameForTesting, "Sparkle License")
        XCTAssertTrue(controller.detailTextForTesting.contains("Sparkle license text"))
    }

    func test_window_uses_compact_top_and_row_side_insets() throws {
        let catalog = ThirdPartyLicenseCatalog(entries: [
            ThirdPartyLicenseEntry(
                id: "ghostty",
                displayName: "Ghostty",
                version: "e75f895",
                licenseName: "MIT License",
                spdxID: "MIT",
                sourceURLString: "https://github.com/ghostty-org/ghostty",
                homepageURLString: nil,
                fullText: "Permission is hereby granted..."
            ),
        ])
        let controller = LicensesWindowController(catalog: catalog)
        addTeardownBlock { controller.window?.close() }

        controller.show(sender: nil)
        waitForLayout()

        XCTAssertEqual(controller.contentTopInsetForTesting, 10)
        XCTAssertEqual(controller.rowSelectionHorizontalInsetForTesting, 6)
        XCTAssertEqual(controller.rowLabelHorizontalInsetForTesting, 8)
    }

    private func waitForLayout(_ description: String = "layout settled", delay: TimeInterval = 0.1) {
        let expectation = expectation(description: description)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }
}
