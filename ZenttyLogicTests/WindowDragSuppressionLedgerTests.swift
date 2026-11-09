import XCTest
@testable import Zentty

final class WindowDragSuppressionLedgerTests: XCTestCase {
    func test_single_holder_restores_baseline_on_release() {
        var ledger = WindowDragSuppressionLedger()

        XCTAssertEqual(ledger.acquire(.proxyHover, currentIsMovable: true), false)
        XCTAssertEqual(ledger.release(.proxyHover), true)
        XCTAssertTrue(ledger.holders.isEmpty)
    }

    func test_interleaved_hover_and_press_restore_original_baseline() {
        let releaseOrders: [[WindowDragSuppressionHolder]] = [
            [.proxyHover, .armedMouseEvent],
            [.armedMouseEvent, .proxyHover],
        ]

        for order in releaseOrders {
            var ledger = WindowDragSuppressionLedger()
            let isMovableDuringHover = ledger.acquire(.proxyHover, currentIsMovable: true)
            XCTAssertFalse(isMovableDuringHover)
            _ = ledger.acquire(.armedMouseEvent, currentIsMovable: isMovableDuringHover)

            XCTAssertNil(ledger.release(order[0]), "first release in \(order)")
            XCTAssertEqual(ledger.release(order[1]), true, "last release in \(order)")
        }
    }

    func test_intentionally_immovable_window_keeps_false_baseline() {
        var ledger = WindowDragSuppressionLedger()

        _ = ledger.acquire(.proxyHover, currentIsMovable: false)
        _ = ledger.acquire(.armedMouseEvent, currentIsMovable: false)

        XCTAssertNil(ledger.release(.armedMouseEvent))
        XCTAssertEqual(ledger.release(.proxyHover), false)
    }

    func test_reacquiring_a_held_holder_keeps_the_captured_baseline() {
        var ledger = WindowDragSuppressionLedger()

        _ = ledger.acquire(.proxyHover, currentIsMovable: true)
        _ = ledger.acquire(.proxyHover, currentIsMovable: false)

        XCTAssertEqual(ledger.release(.proxyHover), true)
    }

    func test_releasing_a_holder_that_never_acquired_changes_nothing() {
        var ledger = WindowDragSuppressionLedger()
        XCTAssertNil(ledger.release(.armedMouseEvent))

        _ = ledger.acquire(.proxyHover, currentIsMovable: true)
        XCTAssertNil(ledger.release(.armedMouseEvent))
        XCTAssertEqual(ledger.holders, [.proxyHover])
    }

    func test_baseline_is_recaptured_after_all_holders_release() {
        var ledger = WindowDragSuppressionLedger()

        _ = ledger.acquire(.proxyPress, currentIsMovable: true)
        _ = ledger.release(.proxyPress)
        _ = ledger.acquire(.proxyPress, currentIsMovable: false)

        XCTAssertEqual(ledger.release(.proxyPress), false)
    }
}
