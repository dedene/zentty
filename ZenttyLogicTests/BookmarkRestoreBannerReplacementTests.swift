import AppKit
import XCTest
@testable import Zentty

@MainActor
final class BookmarkRestoreBannerReplacementTests: XCTestCase {
    func test_new_restore_banner_replaces_the_previous_one() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let unrelatedSubview = NSView()
        host.addSubview(unrelatedSubview)
        let first = BookmarkRestoreBannerView(fallbackCount: 1, onEdit: {})
        let second = BookmarkRestoreBannerView(fallbackCount: 2, onEdit: {})

        first.present(over: host)
        second.present(over: host)

        XCTAssertNil(first.superview)
        XCTAssertTrue(second.superview === host)
        XCTAssertTrue(unrelatedSubview.superview === host)
    }
}
