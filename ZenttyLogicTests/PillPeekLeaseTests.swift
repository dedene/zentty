import XCTest
@testable import Zentty

/// Lend and give back: the pill peek holds at most one pane's container,
/// keeps it through a fade-out it can cancel, and hands it back at once when
/// another pill is hovered or the pane stops being a pill.
final class PillPeekLeaseTests: XCTestCase {
    private let a = PaneID("a")
    private let b = PaneID("b")

    func test_hover_lends_and_fades_in() {
        var lease = PillPeekLease()

        XCTAssertEqual(lease.hover(a), [.lend(a), .fadeIn])
        XCTAssertEqual(lease.phase, .showing(a))
        XCTAssertEqual(lease.visiblePaneID, a)
        XCTAssertEqual(lease.heldPaneID, a)
    }

    func test_hovering_the_same_pill_again_does_nothing() {
        var lease = PillPeekLease()
        _ = lease.hover(a)

        XCTAssertEqual(lease.hover(a), [])
        XCTAssertEqual(lease.phase, .showing(a))
    }

    func test_hover_out_occludes_and_fades_out_still_holding_the_container() {
        var lease = PillPeekLease()
        _ = lease.hover(a)

        XCTAssertEqual(lease.hover(nil), [.fadeOut])
        XCTAssertEqual(lease.phase, .leaving(a))
        XCTAssertNil(lease.visiblePaneID, "occluded while it fades")
        XCTAssertEqual(lease.heldPaneID, a)

        XCTAssertEqual(lease.fadeOutFinished(a), [.giveBack(a)])
        XCTAssertEqual(lease.phase, .idle)
        XCTAssertNil(lease.heldPaneID)
    }

    func test_hover_out_while_idle_does_nothing() {
        var lease = PillPeekLease()
        XCTAssertEqual(lease.hover(nil), [])
        XCTAssertEqual(lease.fadeOutFinished(a), [])
    }

    func test_re_hovering_mid_fade_keeps_the_loan() {
        var lease = PillPeekLease()
        _ = lease.hover(a)
        _ = lease.hover(nil)

        XCTAssertEqual(lease.hover(a), [.fadeIn])
        XCTAssertEqual(lease.phase, .showing(a))
        XCTAssertEqual(lease.fadeOutFinished(a), [], "the cancelled fade's completion is stale")
        XCTAssertEqual(lease.phase, .showing(a))
    }

    func test_another_pill_gives_the_first_back_before_lending() {
        var lease = PillPeekLease()
        _ = lease.hover(a)

        XCTAssertEqual(lease.hover(b), [.giveBack(a), .lend(b), .fadeIn])
        XCTAssertEqual(lease.phase, .showing(b))
    }

    func test_another_pill_mid_fade_gives_the_first_back_at_once() {
        var lease = PillPeekLease()
        _ = lease.hover(a)
        _ = lease.hover(nil)

        XCTAssertEqual(lease.hover(b), [.giveBack(a), .lend(b), .fadeIn])
        XCTAssertEqual(lease.fadeOutFinished(a), [])
        XCTAssertEqual(lease.phase, .showing(b))
    }

    func test_release_gives_back_a_pane_that_left_the_pill_bar() {
        var lease = PillPeekLease()
        _ = lease.hover(a)

        XCTAssertEqual(lease.release(keeping: [a, b]), [], "still a pill")
        XCTAssertEqual(lease.release(keeping: [b]), [.giveBack(a)])
        XCTAssertEqual(lease.phase, .idle)
    }

    func test_release_mid_fade_gives_back_and_drops_the_fade() {
        var lease = PillPeekLease()
        _ = lease.hover(a)
        _ = lease.hover(nil)

        XCTAssertEqual(lease.release(keeping: []), [.giveBack(a)])
        XCTAssertEqual(lease.fadeOutFinished(a), [])
    }

    func test_lend_failure_returns_to_idle() {
        var lease = PillPeekLease()
        _ = lease.hover(a)

        lease.lendFailed(a)

        XCTAssertEqual(lease.phase, .idle)
        XCTAssertEqual(lease.hover(a), [.lend(a), .fadeIn], "the next hover tries again")
    }
}
