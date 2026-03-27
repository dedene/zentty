import GhosttyKit
import XCTest
@testable import Zentty

@MainActor
final class LibghosttySurfaceActionCoalescerTests: XCTestCase {
    func test_coalescer_keeps_latest_metadata_and_orders_events_in_drain() {
        let coalescer = LibghosttySurfaceActionCoalescer()

        XCTAssertTrue(coalescer.enqueue(.setTitle("first")))
        XCTAssertFalse(coalescer.enqueue(.setTitle("second")))
        XCTAssertFalse(coalescer.enqueue(.pwd("/tmp/first")))
        XCTAssertFalse(coalescer.enqueue(.pwd("/tmp/second")))
        XCTAssertFalse(coalescer.enqueue(.scrollbar(total: 1, len: 2)))
        XCTAssertFalse(coalescer.enqueue(.scrollbar(total: 9, len: 4)))
        XCTAssertFalse(coalescer.enqueue(.mouseShape(GHOSTTY_MOUSE_SHAPE_TEXT)))
        XCTAssertFalse(coalescer.enqueue(.mouseShape(GHOSTTY_MOUSE_SHAPE_POINTER)))

        let progress = TerminalProgressReport(state: .indeterminate, progress: nil)
        XCTAssertFalse(coalescer.enqueue(.progressReport(progress)))

        let commandFinished = LibghosttySurfaceActionPayload.commandFinished(
            exitCode: 0,
            durationNanoseconds: 42
        )
        let notification = LibghosttySurfaceActionPayload.desktopNotification(
            TerminalDesktopNotification(title: "Codex", body: "Needs input")
        )
        let openURL = LibghosttySurfaceActionPayload.openURL("https://example.com")

        XCTAssertFalse(coalescer.enqueue(commandFinished))
        XCTAssertFalse(coalescer.enqueue(notification))
        XCTAssertFalse(coalescer.enqueue(openURL))

        let batch = coalescer.drain()

        guard case .present(let title) = batch.title else {
            return XCTFail("Expected coalesced title")
        }
        guard case .present(let pwd) = batch.pwd else {
            return XCTFail("Expected coalesced pwd")
        }
        guard case .present(let scrollbar) = batch.scrollbar else {
            return XCTFail("Expected coalesced scrollbar")
        }
        guard case .present(let mouseShape) = batch.mouseShape else {
            return XCTFail("Expected coalesced mouse shape")
        }
        guard case .present(let progressReport) = batch.progressReport else {
            return XCTFail("Expected coalesced progress report")
        }

        XCTAssertEqual(title, "second")
        XCTAssertEqual(pwd, "/tmp/second")
        XCTAssertEqual(scrollbar.total, 9)
        XCTAssertEqual(scrollbar.len, 4)
        XCTAssertEqual(mouseShape, GHOSTTY_MOUSE_SHAPE_POINTER)
        XCTAssertEqual(progressReport, progress)
        XCTAssertEqual(
            batch.sequence,
            [
                .title,
                .pwd,
                .scrollbar,
                .mouseShape,
                .progressReport,
                .ordered(commandFinished),
                .ordered(notification),
                .ordered(openURL),
            ]
        )

        XCTAssertTrue(coalescer.enqueue(.setTitle("third")))
    }

    func test_coalescer_preserves_latest_progress_report_including_remove() {
        let coalescer = LibghosttySurfaceActionCoalescer()

        let running = TerminalProgressReport(state: .indeterminate, progress: nil)
        let updatedRunning = TerminalProgressReport(state: .indeterminate, progress: 90)
        let removed = TerminalProgressReport(state: .remove, progress: nil)

        XCTAssertTrue(coalescer.enqueue(.progressReport(running)))
        XCTAssertFalse(coalescer.enqueue(.progressReport(updatedRunning)))
        XCTAssertFalse(coalescer.enqueue(.progressReport(removed)))

        var batch = coalescer.drain()
        guard case .present(let firstProgress) = batch.progressReport else {
            return XCTFail("Expected first progress report")
        }
        XCTAssertEqual(firstProgress, removed)
        XCTAssertEqual(batch.sequence, [.progressReport])

        XCTAssertTrue(coalescer.enqueue(.progressReport(running)))
        XCTAssertFalse(coalescer.enqueue(.progressReport(removed)))
        XCTAssertFalse(coalescer.enqueue(.progressReport(updatedRunning)))

        batch = coalescer.drain()
        guard case .present(let secondProgress) = batch.progressReport else {
            return XCTFail("Expected second progress report")
        }
        XCTAssertEqual(secondProgress, updatedRunning)
    }

    func test_coalescer_preserves_explicit_nil_metadata_clears() {
        let coalescer = LibghosttySurfaceActionCoalescer()

        XCTAssertTrue(coalescer.enqueue(.setTitle(nil)))
        XCTAssertFalse(coalescer.enqueue(.pwd(nil)))

        let batch = coalescer.drain()

        guard case .present(let title) = batch.title else {
            return XCTFail("Expected explicit title clear")
        }
        guard case .present(let pwd) = batch.pwd else {
            return XCTFail("Expected explicit pwd clear")
        }

        XCTAssertNil(title)
        XCTAssertNil(pwd)
        XCTAssertEqual(batch.sequence, [.title, .pwd])
    }

    func test_coalescer_keeps_latest_occurrence_position_across_mixed_action_types() {
        let coalescer = LibghosttySurfaceActionCoalescer()
        let notification = LibghosttySurfaceActionPayload.desktopNotification(
            TerminalDesktopNotification(title: "Codex", body: "Agent ready")
        )

        XCTAssertTrue(coalescer.enqueue(.setTitle("Working ⠋ zentty")))
        XCTAssertFalse(coalescer.enqueue(notification))
        XCTAssertFalse(coalescer.enqueue(.setTitle("Working ⠙ zentty")))

        let batch = coalescer.drain()

        guard case .present(let title) = batch.title else {
            return XCTFail("Expected coalesced title")
        }

        XCTAssertEqual(title, "Working ⠙ zentty")
        XCTAssertEqual(batch.sequence, [.ordered(notification), .title])
    }
}
