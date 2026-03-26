import AppKit
import XCTest
@testable import Zentty

@MainActor
final class SidebarWorkspaceRowButtonTests: XCTestCase {
    func test_working_workspace_row_starts_shimmer_animation() {
        let row = makeRow()

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                detailLines: [
                    WorkspaceSidebarDetailLine(text: "feature/sidebar • project", emphasis: .primary),
                ],
                attentionState: .running,
                isWorking: true
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertTrue(row.isWorkingForTesting)
        XCTAssertTrue(row.shimmerIsAnimatingForTesting)
        XCTAssertTrue(row.statusShimmerIsAnimatingForTesting)
    }

    func test_idle_workspace_row_stops_existing_shimmer_animation() {
        let row = makeRow()

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                isWorking: true
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        XCTAssertTrue(row.shimmerIsAnimatingForTesting)
        XCTAssertTrue(row.statusShimmerIsAnimatingForTesting)

        row.configure(
            with: makeSummary(primaryText: "project"),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertFalse(row.isWorkingForTesting)
        XCTAssertFalse(row.shimmerIsAnimatingForTesting)
        XCTAssertFalse(row.statusShimmerIsAnimatingForTesting)
    }

    func test_working_active_workspace_row_uses_distinct_background_tint() {
        let row = makeRow()
        let theme = ZenttyTheme.fallback(for: nil)

        row.configure(
            with: makeSummary(primaryText: "Claude Code", isActive: true),
            theme: theme,
            animated: false
        )
        let idleBackground = try! XCTUnwrap(row.backgroundColorForTesting?.usingColorSpace(.deviceRGB))

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                isWorking: true,
                isActive: true
            ),
            theme: theme,
            animated: false
        )
        let workingBackground = try! XCTUnwrap(row.backgroundColorForTesting?.usingColorSpace(.deviceRGB))

        XCTAssertGreaterThan(abs(idleBackground.redComponent - workingBackground.redComponent), 0.001)
        XCTAssertGreaterThan(abs(idleBackground.greenComponent - workingBackground.greenComponent), 0.001)
        XCTAssertTrue(row.shimmerIsAnimatingForTesting)
    }

    func test_workspace_row_exposes_plain_status_copy() {
        let row = makeRow(height: 88)

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Needs input",
                detailLines: [
                    WorkspaceSidebarDetailLine(text: "feature/sidebar • project", emphasis: .primary),
                ],
                attentionState: .needsInput
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.statusTextForTesting, "Needs input")
        XCTAssertEqual(row.statusSymbolNameForTesting, "")
    }

    func test_workspace_row_keeps_top_level_broad_status_text_and_interaction_icon() {
        let row = makeRow(height: 88)

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Needs input",
                attentionState: .needsInput,
                interactionKind: .question,
                interactionLabel: "Question",
                interactionSymbolName: "questionmark.circle"
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.statusTextForTesting, "Needs input")
        XCTAssertEqual(row.statusSymbolNameForTesting, "questionmark.circle")
    }

    func test_workspace_row_renders_pane_local_branch_detail_and_status_lines() {
        let row = makeRow(width: 320, height: 110)

        row.configure(
            with: makeSummary(
                primaryText: "General coding assistance session",
                paneRows: [
                    WorkspaceSidebarPaneRow(
                        paneID: PaneID("workspace-main-agent"),
                        primaryText: "General coding assistance session",
                        trailingText: "main",
                        detailText: "…/nimbu",
                        statusText: "╰ Idle",
                        attentionState: nil,
                        isFocused: true,
                        isWorking: false
                    ),
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.primaryTextsForTesting, ["General coding assistance session"])
        XCTAssertEqual(row.primaryTrailingTextsForTesting, ["main"])
        XCTAssertEqual(row.detailTextsForTesting, ["…/nimbu"])
        XCTAssertEqual(row.paneStatusTextsForTesting, ["╰ Idle"])
    }

    func test_workspace_row_keeps_pane_broad_status_text_and_interaction_icon() {
        let row = makeRow(width: 320, height: 110)

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    WorkspaceSidebarPaneRow(
                        paneID: PaneID("workspace-main-agent"),
                        primaryText: "Claude Code",
                        trailingText: nil,
                        detailText: nil,
                        statusText: "╰ Needs input",
                        attentionState: .needsInput,
                        interactionKind: .question,
                        interactionLabel: "Question",
                        interactionSymbolName: "questionmark.circle",
                        isFocused: true,
                        isWorking: false
                    ),
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.paneStatusTextsForTesting, ["╰ Needs input"])
        XCTAssertEqual(row.paneStatusSymbolNamesForTesting, ["questionmark.circle"])
    }

    func test_workspace_row_moves_primary_view_to_focused_pane_position() {
        let row = makeRow(height: 92)

        row.configure(
            with: makeSummary(
                primaryText: "k8s-zenjoy",
                focusedPaneLineIndex: 1,
                detailLines: [
                    WorkspaceSidebarDetailLine(text: "feature/scaleway-transactional-mails", emphasis: .secondary),
                    WorkspaceSidebarDetailLine(text: "Personal", emphasis: .secondary),
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.primaryRowIndexForTesting, 1)
        XCTAssertEqual(row.detailTextsForTesting, ["feature/scaleway-transactional-mails", "Personal"])
    }

    func test_working_workspace_row_uses_text_derived_shimmer_highlight() {
        let row = makeRow()
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                isWorking: true
            ),
            theme: theme,
            animated: false
        )

        XCTAssertLessThan(
            colorDistance(row.shimmerColorForTesting, theme.sidebarWorkingTextHighlight),
            colorDistance(row.shimmerColorForTesting, theme.sidebarGradientStart)
        )
        XCTAssertLessThan(
            colorDistance(row.primaryTextColorForTesting, theme.sidebarWorkingTextHighlight),
            colorDistance(row.primaryTextColorForTesting, theme.sidebarGradientStart)
        )
    }

    func test_working_workspace_row_lifts_top_label_out_of_tertiary_text() {
        let row = makeRow()
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                topLabel: "peter@m1-pro-peter:~",
                primaryText: "Claude Code",
                statusText: "Running",
                attentionState: .running,
                isWorking: true
            ),
            theme: theme,
            animated: false
        )

        XCTAssertGreaterThan(
            row.topLabelColorForTesting.perceivedLuminance,
            theme.tertiaryText.perceivedLuminance
        )
        XCTAssertLessThan(
            colorDistance(row.topLabelColorForTesting, theme.sidebarWorkingTextHighlight),
            colorDistance(row.topLabelColorForTesting, theme.tertiaryText)
        )
    }

    func test_dark_background_with_dark_foreground_keeps_sidebar_row_text_light() {
        let row = makeRow()
        let theme = darkTheme(foreground: "#101418")

        row.configure(
            with: makeSummary(
                topLabel: "peter@m1-pro-peter:~",
                primaryText: "peter@m1-pro-peter:~/Development/Zentty"
            ),
            theme: theme,
            animated: false
        )

        XCTAssertGreaterThan(row.primaryTextColorForTesting.perceivedLuminance, theme.sidebarBackground.perceivedLuminance)
        XCTAssertGreaterThan(row.topLabelColorForTesting.perceivedLuminance, theme.sidebarBackground.perceivedLuminance)
        XCTAssertGreaterThan(row.primaryTextColorForTesting.contrastRatio(against: theme.sidebarBackground), 4.5)
    }

    func test_dark_sidebar_theme_forces_dark_row_appearance() {
        let row = makeRow()
        row.appearance = NSAppearance(named: .aqua)
        let theme = darkTheme(foreground: "#F0F3F6")

        row.configure(
            with: makeSummary(
                topLabel: "peter@m1-pro-peter:~",
                primaryText: "~"
            ),
            theme: theme,
            animated: false
        )

        XCTAssertEqual(row.appearanceMatchForTesting, .darkAqua)
    }

    func test_sidebar_row_disables_vibrancy() {
        XCTAssertFalse(makeRow().allowsVibrancy)
    }

    func test_workspace_row_ignores_legacy_sidebar_accessory_and_artifact_concepts() {
        let row = makeRow(height: 88)

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Needs input",
                detailLines: [
                    WorkspaceSidebarDetailLine(text: "main • …/project", emphasis: .primary),
                ],
                attentionState: .needsInput
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.detailTextsForTesting, ["main • …/project"])
        XCTAssertEqual(row.statusTextForTesting, "Needs input")
    }

    private func makeRow(width: CGFloat = 280, height: CGFloat = 72) -> SidebarWorkspaceRowButton {
        let row = SidebarWorkspaceRowButton(
            workspaceID: WorkspaceID("workspace-main"),
            reducedMotionProvider: { false }
        )
        row.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return row
    }

    private func makeSummary(
        topLabel: String? = nil,
        primaryText: String,
        focusedPaneLineIndex: Int = 0,
        statusText: String? = nil,
        detailLines: [WorkspaceSidebarDetailLine] = [],
        paneRows: [WorkspaceSidebarPaneRow] = [],
        attentionState: WorkspaceAttentionState? = nil,
        interactionKind: PaneInteractionKind? = nil,
        interactionLabel: String? = nil,
        interactionSymbolName: String? = nil,
        isWorking: Bool = false,
        isActive: Bool = false
    ) -> WorkspaceSidebarSummary {
        WorkspaceSidebarSummary(
            workspaceID: WorkspaceID("workspace-main"),
            badgeText: "1",
            topLabel: topLabel,
            primaryText: primaryText,
            focusedPaneLineIndex: focusedPaneLineIndex,
            statusText: statusText,
            detailLines: detailLines,
            paneRows: paneRows,
            overflowText: nil,
            attentionState: attentionState,
            interactionKind: interactionKind,
            interactionLabel: interactionLabel,
            interactionSymbolName: interactionSymbolName,
            isWorking: isWorking,
            isActive: isActive
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

    private func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let left = lhs.srgbClamped
        let right = rhs.srgbClamped
        let red = left.redComponent - right.redComponent
        let green = left.greenComponent - right.greenComponent
        let blue = left.blueComponent - right.blueComponent
        return sqrt((red * red) + (green * green) + (blue * blue))
    }
}
