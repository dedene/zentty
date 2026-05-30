import AppKit
import XCTest
@testable import Zentty

@MainActor
final class MenuBarStatusPillViewTests: AppKitTestCase {
    func test_each_kind_resolves_palette_colors_for_light_appearance() {
        let aqua = NSAppearance(named: .aqua)

        for kind in MenuBarStatusKind.allCases {
            let pill = makePill()
            pill.configure(
                kind: kind,
                text: "Running",
                taskProgress: nil,
                appearance: aqua,
                reduceTransparency: false
            )

            let snapshot = pill.debugSnapshotForTesting
            XCTAssertEqual(snapshot.kind, kind)
            XCTAssertEqual(snapshot.labelText, "Running")

            assertColor(
                snapshot.labelColor,
                equals: MenuBarStatusPalette.labelColor(for: kind, isDark: false)
            )
            assertColor(
                snapshot.fillColor,
                equals: MenuBarStatusPalette.fillColor(for: kind, isDark: false, reduceTransparency: false)
            )
            assertColor(
                snapshot.borderColor,
                equals: MenuBarStatusPalette.borderColor(for: kind, isDark: false, reduceTransparency: false)
            )
            assertColor(
                snapshot.dotColor,
                equals: MenuBarStatusPalette.dotColor(for: kind, isDark: false)
            )
        }
    }

    func test_dark_appearance_resolves_dark_label_variant() {
        let darkAqua = NSAppearance(named: .darkAqua)
        let pill = makePill()

        pill.configure(
            kind: .running,
            text: "Running",
            taskProgress: nil,
            appearance: darkAqua,
            reduceTransparency: false
        )

        assertColor(
            pill.debugSnapshotForTesting.labelColor,
            equals: MenuBarStatusPalette.labelColor(for: .running, isDark: true)
        )
    }

    func test_progress_visibility_tracks_task_progress() throws {
        let aqua = NSAppearance(named: .aqua)
        let pill = makePill()

        pill.configure(
            kind: .running,
            text: "Running",
            taskProgress: nil,
            appearance: aqua,
            reduceTransparency: false
        )
        XCTAssertFalse(pill.debugSnapshotForTesting.isProgressVisible)

        let progress = try XCTUnwrap(PaneAgentTaskProgress(doneCount: 2, totalCount: 5))
        pill.configure(
            kind: .running,
            text: "Running",
            taskProgress: progress,
            appearance: aqua,
            reduceTransparency: false
        )
        XCTAssertTrue(pill.debugSnapshotForTesting.isProgressVisible)
    }

    func test_intrinsic_width_grows_with_label_length() {
        let aqua = NSAppearance(named: .aqua)

        let shortPill = makePill()
        shortPill.configure(
            kind: .running,
            text: "Go",
            taskProgress: nil,
            appearance: aqua,
            reduceTransparency: false
        )

        let longPill = makePill()
        longPill.configure(
            kind: .running,
            text: "Running a very long status label",
            taskProgress: nil,
            appearance: aqua,
            reduceTransparency: false
        )

        XCTAssertGreaterThan(shortPill.debugSnapshotForTesting.intrinsicSize.width, 0)
        XCTAssertGreaterThan(
            longPill.debugSnapshotForTesting.intrinsicSize.width,
            shortPill.debugSnapshotForTesting.intrinsicSize.width
        )
    }

    func test_reduce_transparency_bumps_fill_alpha() throws {
        let aqua = NSAppearance(named: .aqua)

        let normalPill = makePill()
        normalPill.configure(
            kind: .running,
            text: "Running",
            taskProgress: nil,
            appearance: aqua,
            reduceTransparency: false
        )

        let reducedPill = makePill()
        reducedPill.configure(
            kind: .running,
            text: "Running",
            taskProgress: nil,
            appearance: aqua,
            reduceTransparency: true
        )

        let normalAlpha = try XCTUnwrap(normalPill.debugSnapshotForTesting.fillColor).srgbClamped.alphaComponent
        let reducedAlpha = try XCTUnwrap(reducedPill.debugSnapshotForTesting.fillColor).srgbClamped.alphaComponent

        XCTAssertGreaterThan(reducedAlpha, normalAlpha)
    }

    func test_label_truncates_when_pill_framed_narrower_than_intrinsic() throws {
        let aqua = NSAppearance(named: .aqua)
        let pill = makePill()
        pill.configure(
            kind: .running,
            text: "An unusually long status that exceeds the pill",
            taskProgress: nil,
            appearance: aqua,
            reduceTransparency: false
        )
        let intrinsicWidth = pill.intrinsicContentSize.width

        // Frame it much narrower than it wants; the label must stay inside the
        // capsule (truncating) rather than overflowing into the row.
        pill.frame = NSRect(x: 0, y: 0, width: 60, height: 18)
        pill.layoutSubtreeIfNeeded()

        let label = try XCTUnwrap(
            pill.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("unusually") }
        )
        XCTAssertLessThanOrEqual(label.frame.maxX, pill.bounds.width)
        XCTAssertLessThan(label.frame.width, intrinsicWidth)
    }

    func test_reveal_detail_is_vertically_aligned_with_label() throws {
        let aqua = NSAppearance(named: .aqua)
        let pill = makePill()
        let progress = try XCTUnwrap(PaneAgentTaskProgress(doneCount: 1, totalCount: 4))
        pill.configure(
            kind: .running,
            text: "Running",
            taskProgress: progress,
            appearance: aqua,
            reduceTransparency: false
        )
        pill.setRevealed(true, animated: false, reducedMotion: true)
        pill.frame = NSRect(x: 0, y: 0, width: pill.intrinsicContentSize.width, height: 18)
        pill.layoutSubtreeIfNeeded()

        let label = try XCTUnwrap(
            pill.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Running" }
        )
        let reveal = try XCTUnwrap(pill.subviews.compactMap { $0 as? SidebarTaskProgressRevealView }.first)
        XCTAssertGreaterThan(reveal.frame.width, 0, "reveal must be laid out with width when revealed")
        XCTAssertEqual(
            reveal.frame.midY,
            label.frame.midY,
            accuracy: 0.5,
            "the hover-reveal detail must share the status label's vertical center"
        )
    }

    // MARK: - Helpers

    private func makePill() -> MenuBarStatusPillView {
        MenuBarStatusPillView(frame: NSRect(x: 0, y: 0, width: 200, height: 18))
    }

    private func assertColor(
        _ actual: NSColor?,
        equals expected: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("Expected a color but got nil", file: file, line: line)
            return
        }

        let lhs = actual.srgbClamped
        let rhs = expected.srgbClamped
        XCTAssertEqual(lhs.redComponent, rhs.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(lhs.greenComponent, rhs.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(lhs.blueComponent, rhs.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(lhs.alphaComponent, rhs.alphaComponent, accuracy: 0.001, file: file, line: line)
    }
}
