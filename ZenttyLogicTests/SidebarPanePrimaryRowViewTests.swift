import AppKit
import XCTest
@testable import Zentty

@MainActor
final class SidebarPanePrimaryRowViewTests: AppKitTestCase {
    func test_remote_indicator_hides_when_not_remote() {
        let view = SidebarPanePrimaryRowView()

        view.configureRemoteIndicator(isRemote: false, label: nil)

        XCTAssertFalse(view.remoteIconIsVisibleForTesting)
        XCTAssertNil(view.remoteIconToolTipForTesting)
        XCTAssertEqual(view.remoteIconAccessibilityLabelForTesting, "")
    }

    func test_remote_indicator_shows_cloud_icon_without_label() {
        let view = SidebarPanePrimaryRowView()

        view.configureRemoteIndicator(isRemote: true, label: nil)

        XCTAssertTrue(view.remoteIconIsVisibleForTesting)
        XCTAssertEqual(view.remoteIconSymbolNameForTesting, "cloud.fill")
        XCTAssertEqual(view.remoteIconToolTipForTesting, "Remote session")
        XCTAssertEqual(view.remoteIconAccessibilityLabelForTesting, "Remote session")
    }

    func test_remote_indicator_shows_trimmed_label_in_tooltip_and_accessibility_label() {
        let view = SidebarPanePrimaryRowView()

        view.configureRemoteIndicator(isRemote: true, label: "  prod.example.test  ")

        XCTAssertTrue(view.remoteIconIsVisibleForTesting)
        XCTAssertEqual(view.remoteIconToolTipForTesting, "Remote session: prod.example.test")
        XCTAssertEqual(view.remoteIconAccessibilityLabelForTesting, "Remote session: prod.example.test")
    }

    func test_remote_indicator_remains_visible_after_primary_text_update() {
        let view = SidebarPanePrimaryRowView()
        view.configure(
            primaryText: "ssh",
            trailingText: nil,
            presentationMode: .inline,
            lineCount: 1
        )
        view.configureRemoteIndicator(isRemote: true, label: "prod.example.test")

        view.setPrimaryText("deploy")

        XCTAssertTrue(view.remoteIconIsVisibleForTesting)
        XCTAssertEqual(view.primaryText, "deploy")
    }

    func test_remote_indicator_uses_trailing_color() {
        let view = SidebarPanePrimaryRowView()
        let trailingColor = NSColor.systemTeal

        view.configureRemoteIndicator(isRemote: true, label: nil)
        view.applyColors(
            primaryColor: .systemPink,
            trailingColor: trailingColor,
            isShimmering: true,
            shimmerColor: .systemPurple,
            reducedMotion: false
        )

        XCTAssertEqual(view.remoteIconTintColorForTesting, trailingColor)
    }
}
