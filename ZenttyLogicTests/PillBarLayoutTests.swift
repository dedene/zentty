import XCTest
@testable import Zentty

/// Pill bar geometry and content (UX spec §9): right-aligned, newest
/// rightmost, compression to dot + short name, then a "+N" overflow.
@MainActor
final class PillBarLayoutTests: XCTestCase {
    private let bar = CGRect(x: 0, y: 0, width: 600, height: PillBarLayout.barHeight)

    // MARK: - Layout

    func test_pills_that_fit_are_right_aligned_with_the_newest_rightmost() {
        let result = PillBarLayout.layout(fullWidths: [100, 120], compactWidths: [60, 60], in: bar)

        XCTAssertEqual(result.style, .full)
        XCTAssertEqual(result.overflow, [])
        XCTAssertNil(result.overflowFrame)
        let newest = try? XCTUnwrap(result.frames[1])
        let oldest = try? XCTUnwrap(result.frames[0])
        XCTAssertEqual(newest?.maxX, bar.maxX - PillBarLayout.horizontalInset)
        XCTAssertEqual(newest?.width, 120)
        XCTAssertEqual(oldest?.maxX, (newest?.minX ?? 0) - PillBarLayout.spacing)
        XCTAssertEqual(oldest?.height, PillBarLayout.pillHeight)
        XCTAssertEqual(oldest?.minY, PillBarLayout.pillBottomInset)
    }

    func test_pills_compress_to_dot_and_short_name_before_overflowing() {
        let result = PillBarLayout.layout(
            fullWidths: [300, 300, 300],
            compactWidths: [80, 80, 80],
            in: bar
        )

        XCTAssertEqual(result.style, .compact)
        XCTAssertEqual(result.overflow, [])
        XCTAssertEqual(result.frames.count, 3)
        XCTAssertEqual(result.frames[2]?.width, 80)
    }

    func test_overflow_keeps_the_newest_pills_and_menus_the_oldest() {
        // 576pt usable: "+N" (40) + 5 × (6 + 100) = 570 fits, a sixth doesn't.
        let count = 8
        let result = PillBarLayout.layout(
            fullWidths: Array(repeating: 300, count: count),
            compactWidths: Array(repeating: 100, count: count),
            in: bar
        )

        XCTAssertEqual(result.style, .compact)
        XCTAssertEqual(result.overflow, [0, 1, 2])
        XCTAssertEqual(Set(result.frames.keys), Set(3..<8))
        let overflowFrame = try? XCTUnwrap(result.overflowFrame)
        XCTAssertEqual(overflowFrame?.width, PillBarLayout.overflowWidth)
        XCTAssertEqual(overflowFrame?.maxX, (result.frames[3]?.minX ?? 0) - PillBarLayout.spacing)
        XCTAssertGreaterThanOrEqual(overflowFrame?.minX ?? -1, PillBarLayout.horizontalInset)
    }

    func test_no_pills_lays_out_nothing() {
        let result = PillBarLayout.layout(fullWidths: [], compactWidths: [], in: bar)

        XCTAssertTrue(result.frames.isEmpty)
        XCTAssertTrue(result.overflow.isEmpty)
    }

    func test_release_promotes_only_well_above_the_bar() {
        XCTAssertFalse(PillBarLayout.promotesToPip(releasePoint: CGPoint(x: 10, y: 20), barBounds: bar))
        XCTAssertFalse(PillBarLayout.promotesToPip(
            releasePoint: CGPoint(x: 10, y: bar.maxY + PillBarLayout.promoteDistance - 1),
            barBounds: bar
        ))
        XCTAssertTrue(PillBarLayout.promotesToPip(
            releasePoint: CGPoint(x: 10, y: bar.maxY + PillBarLayout.promoteDistance),
            barBounds: bar
        ))
    }

    func test_nearest_corner_is_the_drop_points_quadrant() {
        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 600)

        XCTAssertEqual(FloatLayout.nearestCorner(to: CGPoint(x: 100, y: 500), in: canvas), .topLeft)
        XCTAssertEqual(FloatLayout.nearestCorner(to: CGPoint(x: 900, y: 500), in: canvas), .topRight)
        XCTAssertEqual(FloatLayout.nearestCorner(to: CGPoint(x: 100, y: 100), in: canvas), .bottomLeft)
        XCTAssertEqual(FloatLayout.nearestCorner(to: CGPoint(x: 900, y: 100), in: canvas), .bottomRight)
    }

    // MARK: - Content

    func test_content_lists_only_minimized_floats_by_pill_order() {
        let worklane = makeWorklane(floats: [
            float("float", mode: .floating),
            float("newer", mode: .minimized(order: 1)),
            float("pip", mode: .pip(corner: .bottomRight, order: 0)),
            float("older", mode: .minimized(order: 0)),
        ])

        let content = PillBarContent(worklane: worklane)

        XCTAssertEqual(content.items.map(\.paneID), [PaneID("older"), PaneID("newer")])
        XCTAssertEqual(content.items.map(\.name), ["older", "newer"])
    }

    func test_content_reads_short_cwd_and_status() {
        var presentation = PanePresentationState()
        presentation.runtimePhase = .needsInput
        var auxiliary = PaneAuxiliaryState(
            shellContext: PaneShellContext(
                scope: .local, path: "/Users/me/Development/zentty", home: "/Users/me", user: "me", host: "mac"
            ),
            presentation: presentation
        )
        auxiliary.lifetime = .persistent
        let worklane = makeWorklane(
            floats: [float("agent", mode: .minimized(order: 0))],
            auxiliary: [PaneID("agent"): auxiliary]
        )

        let item = try? XCTUnwrap(PillBarContent(worklane: worklane).items.first)

        XCTAssertEqual(item?.subtitle, "zentty")
        XCTAssertEqual(item?.attention, .needsInput)
        XCTAssertEqual(item?.statusWord, "Needs input")
        XCTAssertTrue(item?.accessibilityLabel.hasSuffix(", Needs input, minimized") == true)
    }

    func test_short_location_keeps_home_and_drops_a_repeat_of_the_name() {
        let home = PaneShellContext(scope: .local, path: "/Users/me", home: "/Users/me", user: nil, host: nil)
        let repo = PaneShellContext(scope: .local, path: "/Users/me/zentty", home: "/Users/me", user: nil, host: nil)

        XCTAssertEqual(PillBarContent.shortLocation(home, name: "zsh"), "~")
        XCTAssertNil(PillBarContent.shortLocation(repo, name: "zentty"))
        XCTAssertNil(PillBarContent.shortLocation(nil, name: "zsh"))
    }

    func test_idle_pill_has_no_status_word() {
        let item = PillBarItem(paneID: PaneID("a"), name: "logs", subtitle: nil, attention: nil)

        XCTAssertNil(item.statusWord)
        XCTAssertEqual(item.accessibilityLabel, "logs, minimized")
    }

    // MARK: - Fixtures

    private func float(_ id: String, mode: FloatingPaneMode) -> FloatingPaneState {
        FloatingPaneState(
            pane: PaneState(id: PaneID(id), title: id),
            mode: mode,
            floatFrame: NormalizedRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            stackOrder: 0,
            origin: nil
        )
    }

    private func makeWorklane(
        floats: [FloatingPaneState],
        auxiliary: [PaneID: PaneAuxiliaryState] = [:]
    ) -> WorklaneState {
        WorklaneState(
            id: WorklaneID("wl"),
            title: nil,
            paneStripState: PaneStripState(panes: [PaneState(id: PaneID("tile"), title: "tile")], focusedPaneID: PaneID("tile")),
            auxiliaryStateByPaneID: auxiliary,
            floatingPanes: floats
        )
    }
}
