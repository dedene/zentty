import AppKit
import XCTest
@testable import Zentty

@MainActor
final class SidebarWorklaneRowButtonColorTests: AppKitTestCase {
    func test_no_color_leaves_tint_layer_clear() {
        let row = makeRow()
        row.configure(with: makeSummary(color: nil, isActive: false), theme: ZenttyTheme.fallback(for: nil), animated: false)
        let cg = row.tintLayerBackgroundColorForTesting ?? NSColor.clear.cgColor
        XCTAssertEqual(cg.alpha, 0, accuracy: 0.001)
    }

    func test_inactive_colored_row_uses_inactive_alpha() {
        let row = makeRow()
        row.configure(with: makeSummary(color: .red, isActive: false), theme: ZenttyTheme.fallback(for: nil), animated: false)
        let alpha = row.tintLayerBackgroundColorForTesting?.alpha ?? -1
        XCTAssertEqual(alpha, WorklaneColor.Alpha.inactive, accuracy: 0.001)
    }

    func test_hovered_colored_row_uses_hover_alpha() {
        let row = makeRow()
        row.configure(with: makeSummary(color: .blue, isActive: false), theme: ZenttyTheme.fallback(for: nil), animated: false)
        row.setHoveredForTesting(true)
        let alpha = row.tintLayerBackgroundColorForTesting?.alpha ?? -1
        XCTAssertEqual(alpha, WorklaneColor.Alpha.hover, accuracy: 0.001)
    }

    func test_active_colored_row_uses_active_alpha() {
        let row = makeRow()
        row.configure(with: makeSummary(color: .green, isActive: true), theme: ZenttyTheme.fallback(for: nil), animated: false)
        let alpha = row.tintLayerBackgroundColorForTesting?.alpha ?? -1
        XCTAssertEqual(alpha, WorklaneColor.Alpha.active, accuracy: 0.001)
    }

    func test_clearing_color_resets_tint() {
        let row = makeRow()
        let theme = ZenttyTheme.fallback(for: nil)
        row.configure(with: makeSummary(color: .purple, isActive: false), theme: theme, animated: false)
        XCTAssertGreaterThan(row.tintLayerBackgroundColorForTesting?.alpha ?? 0, 0)

        row.configure(with: makeSummary(color: nil, isActive: false), theme: theme, animated: false)
        XCTAssertEqual(row.tintLayerBackgroundColorForTesting?.alpha ?? -1, 0, accuracy: 0.001)
    }

    func test_colored_inactive_working_row_shimmer_preserves_worklane_hue_and_brightens_on_dark_sidebar() throws {
        let row = makeRow()
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(color: .blue, isActive: false, isWorking: true),
            theme: theme,
            animated: false
        )

        let base = try XCTUnwrap(hsbComponents(WorklaneColor.blue.tint(alpha: 1)))
        let shimmer = try XCTUnwrap(hsbComponents(row.shimmerColorForTesting))

        XCTAssertEqual(shimmer.hue, base.hue, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(shimmer.saturation, base.saturation)
        XCTAssertGreaterThan(shimmer.brightness, base.brightness)
    }

    func test_colored_active_working_row_shimmer_preserves_hue_and_uses_darker_shade() throws {
        let row = makeRow()
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(color: .purple, isActive: true, isWorking: true),
            theme: theme,
            animated: false
        )

        let base = try XCTUnwrap(hsbComponents(WorklaneColor.purple.tint(alpha: 1)))
        let shimmer = try XCTUnwrap(hsbComponents(row.shimmerColorForTesting))

        XCTAssertEqual(shimmer.hue, base.hue, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(shimmer.saturation, base.saturation)
        XCTAssertLessThan(shimmer.brightness, base.brightness)
    }

    func test_colored_worklane_status_shimmer_keeps_semantic_hue() throws {
        let row = makeRow()
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                color: .pink,
                statusText: "Running",
                attentionState: .running,
                taskProgress: PaneAgentTaskProgress(doneCount: 2, totalCount: 5),
                isWorking: true
            ),
            theme: theme,
            animated: false
        )

        let base = try XCTUnwrap(hsbComponents(WorklaneColor.pink.tint(alpha: 1)))
        let expected = try XCTUnwrap(hsbComponents(statusShimmerBaseColor(theme)))
        let shimmer = try XCTUnwrap(hsbComponents(row.statusShimmerColorForTesting))

        XCTAssertNotEqual(shimmer.hue, base.hue, accuracy: 0.02)
        XCTAssertEqual(shimmer.hue, expected.hue, accuracy: 0.02)
        XCTAssertEqual(row.statusTextColorForTesting.srgbClamped, theme.statusRunning.srgbClamped)
        XCTAssertEqual(row.statusProgressColorForTesting.srgbClamped, theme.statusRunning.srgbClamped)
    }

    func test_colored_worklane_focused_pane_title_shimmer_is_desaturated_while_status_stays_semantic() throws {
        let row = makeRow(width: 320, height: 110)
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                color: .pink,
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("pane-agent"),
                        primaryText: "Claude Code",
                        trailingText: "main",
                        detailText: ".../zentty",
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    ),
                ],
                isWorking: true
            ),
            theme: theme,
            animated: false
        )

        let base = try XCTUnwrap(hsbComponents(WorklaneColor.pink.tint(alpha: 1)))
        let expectedStatus = try XCTUnwrap(hsbComponents(statusShimmerBaseColor(theme)))
        let primaryShimmer = try XCTUnwrap(row.firstPanePrimaryShimmerColorForTesting)
        let statusShimmer = try XCTUnwrap(row.firstPaneStatusShimmerColorForTesting)
        let primaryComponents = try XCTUnwrap(hsbComponents(primaryShimmer))

        XCTAssertEqual(primaryComponents.hue, base.hue, accuracy: 0.02)
        XCTAssertLessThan(primaryComponents.saturation, base.saturation)
        XCTAssertLessThan(primaryShimmer.srgbClamped.alphaComponent, statusShimmer.srgbClamped.alphaComponent)
        XCTAssertEqual(try XCTUnwrap(hsbComponents(statusShimmer)).hue, expectedStatus.hue, accuracy: 0.02)
        XCTAssertEqual(row.firstPaneStatusTextColorForTesting?.srgbClamped, theme.statusRunning.srgbClamped)
    }

    func test_colored_worklane_unfocused_pane_title_shimmer_is_much_more_neutral_than_focused_title() throws {
        let focusedRow = makeRow(width: 320, height: 110)
        let unfocusedRow = makeRow(width: 320, height: 110)
        let theme = darkTheme(foreground: "#F0F3F6")

        focusedRow.configure(
            with: makeSummary(
                color: .pink,
                paneRows: [makePaneRow(isFocused: true)],
                isWorking: true
            ),
            theme: theme,
            animated: false
        )
        unfocusedRow.configure(
            with: makeSummary(
                color: .pink,
                paneRows: [makePaneRow(isFocused: false)],
                isWorking: true
            ),
            theme: theme,
            animated: false
        )

        let focusedShimmer = try XCTUnwrap(focusedRow.firstPanePrimaryShimmerColorForTesting)
        let unfocusedShimmer = try XCTUnwrap(unfocusedRow.firstPanePrimaryShimmerColorForTesting)
        let focused = try XCTUnwrap(hsbComponents(focusedShimmer))
        let unfocused = try XCTUnwrap(hsbComponents(unfocusedShimmer))

        XCTAssertLessThan(unfocused.saturation, focused.saturation)
        XCTAssertLessThan(unfocused.brightness, focused.brightness)
        XCTAssertLessThan(unfocusedShimmer.srgbClamped.alphaComponent, focusedShimmer.srgbClamped.alphaComponent)
    }

    private func makeRow(width: CGFloat = 280, height: CGFloat = 72) -> SidebarWorklaneRowButton {
        let row = SidebarWorklaneRowButton(
            worklaneID: WorklaneID("worklane-main"),
            reducedMotionProvider: { false }
        )
        row.frame = NSRect(x: 0, y: 0, width: width, height: height)
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    private func makeSummary(
        color: WorklaneColor?,
        isActive: Bool = false,
        statusText: String? = nil,
        paneRows: [WorklaneSidebarPaneRow] = [],
        attentionState: WorklaneAttentionState? = nil,
        taskProgress: PaneAgentTaskProgress? = nil,
        isWorking: Bool = false
    ) -> WorklaneSidebarSummary {
        WorklaneSidebarSummary(
            worklaneID: WorklaneID("worklane-main"),
            badgeText: "1",
            primaryText: "project",
            statusText: statusText,
            paneRows: paneRows,
            attentionState: attentionState,
            taskProgress: taskProgress,
            isWorking: isWorking,
            isActive: isActive,
            color: color
        )
    }

    private func makePaneRow(isFocused: Bool) -> WorklaneSidebarPaneRow {
        WorklaneSidebarPaneRow(
            paneID: PaneID("pane-agent"),
            primaryText: "Claude Code",
            trailingText: "main",
            detailText: ".../zentty",
            statusText: "Running",
            attentionState: .running,
            isFocused: isFocused,
            isWorking: true
        )
    }

    private func darkTheme(foreground: String) -> ZenttyTheme {
        ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: foreground)!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.9,
                backgroundBlurRadius: 25
            )
        )
    }

    private func hsbComponents(_ color: NSColor) -> (
        hue: CGFloat,
        saturation: CGFloat,
        brightness: CGFloat,
        alpha: CGFloat
    )? {
        guard let converted = color.usingColorSpace(.deviceRGB) else {
            return nil
        }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        converted.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (hue, saturation, brightness, alpha)
    }

    private func statusShimmerBaseColor(_ theme: ZenttyTheme) -> NSColor {
        theme.statusRunning.adjustedHSB(
            saturationBy: 0.18,
            brightnessBy: 0.10
        )
    }
}
