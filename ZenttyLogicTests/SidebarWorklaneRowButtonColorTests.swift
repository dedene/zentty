import AppKit
import XCTest
@testable import Zentty

@MainActor
final class SidebarWorklaneRowButtonColorTests: AppKitTestCase {
    func test_style_resolver_tint_uses_hover_alpha_only_when_pane_row_is_not_hovered() {
        let tint = SidebarWorklaneRowStyleResolver.tintColor(
            worklaneColor: .red,
            isActive: false,
            isHovered: true,
            isPaneRowHovered: false
        )
        let paneHoveredTint = SidebarWorklaneRowStyleResolver.tintColor(
            worklaneColor: .red,
            isActive: false,
            isHovered: true,
            isPaneRowHovered: true
        )

        XCTAssertEqual(tint.alpha, WorklaneColor.Alpha.hover, accuracy: 0.001)
        XCTAssertEqual(paneHoveredTint.alpha, WorklaneColor.Alpha.inactive, accuracy: 0.001)
    }

    func test_no_color_leaves_tint_layer_clear() {
        let row = makeRow()
        row.configure(with: makeSummary(color: nil, isActive: false), theme: ZenttyTheme.fallback(for: nil), animated: false)
        let cg = row.debugSnapshotForTesting.tintLayerBackgroundColor ?? NSColor.clear.cgColor
        XCTAssertEqual(cg.alpha, 0, accuracy: 0.001)
    }

    func test_inactive_colored_row_uses_inactive_alpha() {
        let row = makeRow()
        row.configure(with: makeSummary(color: .red, isActive: false), theme: ZenttyTheme.fallback(for: nil), animated: false)
        let alpha = row.debugSnapshotForTesting.tintLayerBackgroundColor?.alpha ?? -1
        XCTAssertEqual(alpha, WorklaneColor.Alpha.inactive, accuracy: 0.001)
    }

    func test_hovered_colored_row_uses_hover_alpha() {
        let row = makeRow()
        row.configure(with: makeSummary(color: .blue, isActive: false), theme: ZenttyTheme.fallback(for: nil), animated: false)
        row.performDebugInteractionForTesting(.setHovered(true))
        let alpha = row.debugSnapshotForTesting.tintLayerBackgroundColor?.alpha ?? -1
        XCTAssertEqual(alpha, WorklaneColor.Alpha.hover, accuracy: 0.001)
    }

    func test_active_colored_row_uses_active_alpha() {
        let row = makeRow()
        row.configure(with: makeSummary(color: .green, isActive: true), theme: ZenttyTheme.fallback(for: nil), animated: false)
        let alpha = row.debugSnapshotForTesting.tintLayerBackgroundColor?.alpha ?? -1
        XCTAssertEqual(alpha, WorklaneColor.Alpha.active, accuracy: 0.001)
    }

    func test_clearing_color_resets_tint() {
        let row = makeRow()
        let theme = ZenttyTheme.fallback(for: nil)
        row.configure(with: makeSummary(color: .purple, isActive: false), theme: theme, animated: false)
        XCTAssertGreaterThan(row.debugSnapshotForTesting.tintLayerBackgroundColor?.alpha ?? 0, 0)

        row.configure(with: makeSummary(color: nil, isActive: false), theme: theme, animated: false)
        XCTAssertEqual(row.debugSnapshotForTesting.tintLayerBackgroundColor?.alpha ?? -1, 0, accuracy: 0.001)
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
        let shimmer = try XCTUnwrap(hsbComponents(row.debugSnapshotForTesting.shimmerColor))

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
        let shimmer = try XCTUnwrap(hsbComponents(row.debugSnapshotForTesting.shimmerColor))

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
        let shimmer = try XCTUnwrap(hsbComponents(row.debugSnapshotForTesting.statusShimmerColor))

        XCTAssertNotEqual(shimmer.hue, base.hue, accuracy: 0.02)
        XCTAssertEqual(shimmer.hue, expected.hue, accuracy: 0.02)
        XCTAssertEqual(row.debugSnapshotForTesting.statusTextColor.srgbClamped, theme.statusRunning.srgbClamped)
        XCTAssertEqual(row.debugSnapshotForTesting.statusProgressColor.srgbClamped, theme.statusRunning.srgbClamped)
    }

    func test_compacting_status_uses_running_status_color() throws {
        let row = makeRow()
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                color: nil,
                statusText: "Compacting",
                attentionState: .running,
                isWorking: true
            ),
            theme: theme,
            animated: false
        )

        XCTAssertEqual(row.debugSnapshotForTesting.statusTextColor.srgbClamped, theme.statusRunning.srgbClamped)
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
        let primaryShimmer = try XCTUnwrap(row.debugSnapshotForTesting.firstPanePrimaryShimmerColor)
        let statusShimmer = try XCTUnwrap(row.debugSnapshotForTesting.firstPaneStatusShimmerColor)
        let primaryComponents = try XCTUnwrap(hsbComponents(primaryShimmer))

        XCTAssertEqual(primaryComponents.hue, base.hue, accuracy: 0.02)
        XCTAssertLessThan(primaryComponents.saturation, base.saturation)
        XCTAssertLessThan(primaryShimmer.srgbClamped.alphaComponent, statusShimmer.srgbClamped.alphaComponent)
        XCTAssertEqual(try XCTUnwrap(hsbComponents(statusShimmer)).hue, expectedStatus.hue, accuracy: 0.02)
        XCTAssertEqual(row.debugSnapshotForTesting.firstPaneStatusTextColor?.srgbClamped, theme.statusRunning.srgbClamped)
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

        let focusedShimmer = try XCTUnwrap(focusedRow.debugSnapshotForTesting.firstPanePrimaryShimmerColor)
        let unfocusedShimmer = try XCTUnwrap(unfocusedRow.debugSnapshotForTesting.firstPanePrimaryShimmerColor)
        let focused = try XCTUnwrap(hsbComponents(focusedShimmer))
        let unfocused = try XCTUnwrap(hsbComponents(unfocusedShimmer))

        XCTAssertLessThan(unfocused.saturation, focused.saturation)
        XCTAssertLessThan(unfocused.brightness, focused.brightness)
        XCTAssertLessThan(unfocusedShimmer.srgbClamped.alphaComponent, focusedShimmer.srgbClamped.alphaComponent)
    }

    // MARK: - Vivid selected-row per-worklane color

    func test_subtle_selected_chrome_with_lane_color_is_identity_dark() {
        assertSubtleSelectedChromeIsIdentity(theme: makeTheme(dark: true, emphasis: .subtle))
    }

    func test_subtle_selected_chrome_with_lane_color_is_identity_light() {
        assertSubtleSelectedChromeIsIdentity(theme: makeTheme(dark: false, emphasis: .subtle))
    }

    func test_vivid_selected_chrome_without_color_is_identity() {
        let theme = makeTheme(dark: true, emphasis: .vivid)
        let bg = NSColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 0.9)
        let border = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.6, alpha: 0.42)
        let text = NSColor.white

        let chrome = SidebarWorklaneRowStyleResolver.selectedRowChrome(
            worklaneColor: nil,
            activeBackground: bg,
            activeBorder: border,
            activeText: text,
            theme: theme
        )

        assertColorsEqual(chrome.background, bg)
        assertColorsEqual(chrome.border, border)
        assertColorsEqual(chrome.text, text.srgbClamped)
    }

    func test_vivid_selected_chrome_with_lane_color_is_lane_tinted_dark() throws {
        try assertVividLaneChrome(theme: makeTheme(dark: true, emphasis: .vivid), color: .blue)
    }

    func test_vivid_selected_chrome_with_lane_color_is_lane_tinted_light() throws {
        try assertVividLaneChrome(theme: makeTheme(dark: false, emphasis: .vivid), color: .pink)
    }

    func test_vivid_selected_chrome_lane_fill_is_clearly_separated_from_idle() {
        let theme = makeTheme(dark: true, emphasis: .vivid)
        let chrome = SidebarWorklaneRowStyleResolver.selectedRowChrome(
            worklaneColor: .green,
            activeBackground: theme.sidebarButtonActiveBackground,
            activeBorder: theme.sidebarButtonActiveBorder,
            activeText: theme.sidebarButtonActiveText,
            theme: theme
        )
        let surface = theme.sidebarBackground.composited(over: theme.windowBackground)
        let selected = chrome.background.composited(over: surface)
        let idle = theme.sidebarButtonInactiveBackground.composited(over: surface)

        XCTAssertGreaterThan(srgbDistance(selected, idle), 0.12)
    }

    func test_vivid_selected_chrome_text_stays_legible_on_lane_fill() throws {
        for color in WorklaneColor.allCases {
            for dark in [true, false] {
                let theme = makeTheme(dark: dark, emphasis: .vivid)
                let chrome = SidebarWorklaneRowStyleResolver.selectedRowChrome(
                    worklaneColor: color,
                    activeBackground: theme.sidebarButtonActiveBackground,
                    activeBorder: theme.sidebarButtonActiveBorder,
                    activeText: theme.sidebarButtonActiveText,
                    theme: theme
                )
                let surface = theme.sidebarBackground.composited(over: theme.windowBackground)
                let fill = chrome.background.composited(over: surface)
                XCTAssertGreaterThanOrEqual(
                    chrome.text.contrastRatio(against: fill),
                    4.5,
                    "Lane \(color.rawValue) (dark=\(dark)) selected text must clear WCAG AA on its fill"
                )
            }
        }
    }

    func test_vivid_active_lane_row_background_is_lane_tinted_and_differs_from_idle() throws {
        let theme = makeTheme(dark: true, emphasis: .vivid)
        let activeRow = makeRow()
        activeRow.configure(with: makeSummary(color: .blue, isActive: true), theme: theme, animated: false)
        let idleRow = makeRow()
        idleRow.configure(with: makeSummary(color: .blue, isActive: false), theme: theme, animated: false)

        let activeBackground = try XCTUnwrap(activeRow.debugSnapshotForTesting.backgroundColor)
        let idleBackground = try XCTUnwrap(idleRow.debugSnapshotForTesting.backgroundColor)

        let laneHue = try XCTUnwrap(hsbComponents(WorklaneColor.blue.tint(alpha: 1))).hue
        let activeHue = try XCTUnwrap(hsbComponents(activeBackground)).hue
        XCTAssertEqual(activeHue, laneHue, accuracy: 0.06)
        XCTAssertGreaterThan(srgbDistance(activeBackground, idleBackground), 0.1)
    }

    private func assertSubtleSelectedChromeIsIdentity(theme: ZenttyTheme) {
        let bg = NSColor(srgbRed: 0.11, green: 0.22, blue: 0.33, alpha: 0.88)
        let border = NSColor(srgbRed: 0.4, green: 0.5, blue: 0.6, alpha: 0.1)
        let text = NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1)

        let chrome = SidebarWorklaneRowStyleResolver.selectedRowChrome(
            worklaneColor: .red,
            activeBackground: bg,
            activeBorder: border,
            activeText: text,
            theme: theme
        )

        assertColorsEqual(chrome.background, bg)
        assertColorsEqual(chrome.border, border)
        assertColorsEqual(chrome.text, text.srgbClamped)
    }

    private func assertVividLaneChrome(theme: ZenttyTheme, color: WorklaneColor) throws {
        let chrome = SidebarWorklaneRowStyleResolver.selectedRowChrome(
            worklaneColor: color,
            activeBackground: theme.sidebarButtonActiveBackground,
            activeBorder: theme.sidebarButtonActiveBorder,
            activeText: theme.sidebarButtonActiveText,
            theme: theme
        )

        let laneHue = try XCTUnwrap(hsbComponents(color.tint(alpha: 1))).hue
        let fillHue = try XCTUnwrap(hsbComponents(chrome.background)).hue
        XCTAssertEqual(fillHue, laneHue, accuracy: 0.06)

        let borderHue = try XCTUnwrap(hsbComponents(chrome.border)).hue
        XCTAssertEqual(borderHue, laneHue, accuracy: 0.06)
        XCTAssertEqual(chrome.border.alphaComponent, WorklaneColor.Alpha.focusedBorder, accuracy: 0.001)

        // Fill reads as a real, near-opaque tint (not the low-alpha wash).
        XCTAssertGreaterThan(chrome.background.alphaComponent, 0.9)
    }

    private func makeTheme(
        dark: Bool,
        emphasis: AppConfig.Appearance.SidebarSelectionEmphasis
    ) -> ZenttyTheme {
        ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: dark ? "#0A0C10" : "#FBFBFD")!,
                foreground: NSColor(hexString: dark ? "#F0F3F6" : "#1A1C1F")!,
                cursorColor: NSColor(hexString: dark ? "#71B7FF" : "#3366CC")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: dark ? 0.9 : 1.0,
                backgroundBlurRadius: 25
            ),
            reduceTransparency: false,
            sidebarSelectionEmphasis: emphasis
        )
    }

    private func srgbDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let a = lhs.srgbClamped
        let b = rhs.srgbClamped
        let dr = a.redComponent - b.redComponent
        let dg = a.greenComponent - b.greenComponent
        let db = a.blueComponent - b.blueComponent
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    private func assertColorsEqual(
        _ lhs: NSColor,
        _ rhs: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let a = lhs.srgbClamped
        let b = rhs.srgbClamped
        XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.alphaComponent, b.alphaComponent, accuracy: 0.001, file: file, line: line)
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
