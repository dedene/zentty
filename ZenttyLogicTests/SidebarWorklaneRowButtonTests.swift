import AppKit
import XCTest
@testable import Zentty

@MainActor
final class SidebarWorklaneRowButtonTests: XCTestCase {
    func test_working_worklane_row_does_not_animate_until_it_is_hosted_in_a_visible_sidebar() {
        let row = makeRow()

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Running",
                detailLines: [
                    WorklaneSidebarDetailLine(text: "feature/sidebar • project", emphasis: .primary),
                ],
                attentionState: .running,
                isWorking: true
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertTrue(row.isWorkingForTesting)
        XCTAssertFalse(row.shimmerIsAnimatingForTesting)
        XCTAssertFalse(row.statusShimmerIsAnimatingForTesting)
    }

    func test_idle_worklane_row_stays_static_when_it_is_not_hosted_in_a_visible_sidebar() {
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
        XCTAssertFalse(row.shimmerIsAnimatingForTesting)
        XCTAssertFalse(row.statusShimmerIsAnimatingForTesting)

        row.configure(
            with: makeSummary(primaryText: "project"),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertFalse(row.isWorkingForTesting)
        XCTAssertFalse(row.shimmerIsAnimatingForTesting)
        XCTAssertFalse(row.statusShimmerIsAnimatingForTesting)
    }

    func test_working_active_worklane_row_uses_distinct_background_tint() {
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
        XCTAssertFalse(row.shimmerIsAnimatingForTesting)
    }

    func test_worklane_row_exposes_plain_status_copy() {
        let row = makeRow(height: 88)

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Needs input",
                detailLines: [
                    WorklaneSidebarDetailLine(text: "feature/sidebar • project", emphasis: .primary),
                ],
                attentionState: .needsInput
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.statusTextForTesting, "Needs input")
        XCTAssertEqual(row.statusSymbolNameForTesting, "")
    }

    func test_worklane_row_keeps_top_level_broad_status_text_and_interaction_icon() {
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

    func test_worklane_row_renders_pane_local_branch_detail_and_status_lines() {
        let row = makeRow(width: 320, height: 110)

        row.configure(
            with: makeSummary(
                primaryText: "General coding assistance session",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
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

    func test_worklane_row_keeps_pane_broad_status_text_and_interaction_icon() {
        let row = makeRow(width: 320, height: 110)

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
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

    func test_worklane_row_renders_agent_ready_with_success_icon_from_sidebar_summary() {
        let row = makeRow(width: 320, height: 110)
        let paneID = PaneID("worklane-main-agent-ready")
        var auxiliaryState = PaneAuxiliaryState(
            metadata: TerminalMetadata(
                title: "General coding assistance session",
                currentWorkingDirectory: "/Users/peter/Development/Zenjoy/Internal/nimbu",
                processName: "codex",
                gitBranch: "main"
            ),
            agentStatus: PaneAgentStatus(
                tool: .codex,
                state: .idle,
                text: nil,
                artifactLink: nil,
                updatedAt: Date(timeIntervalSince1970: 42),
                hasObservedRunning: true
            )
        )
        auxiliaryState.raw.lastDesktopNotificationText = "Agent run complete"
        auxiliaryState.raw.lastDesktopNotificationDate = Date(timeIntervalSince1970: 42)
        auxiliaryState.presentation = PanePresentationNormalizer.normalize(
            paneTitle: "agent",
            raw: auxiliaryState.raw,
            previous: nil
        )
        let worklane = WorklaneState(
            id: WorklaneID("worklane-main"),
            title: "MAIN",
            paneStripState: PaneStripState(
                panes: [PaneState(id: paneID, title: "agent")],
                focusedPaneID: paneID
            ),
            auxiliaryStateByPaneID: [paneID: auxiliaryState]
        )

        row.configure(
            with: WorklaneSidebarSummaryBuilder.summary(for: worklane, isActive: false),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.paneStatusTextsForTesting, ["Agent ready"])
        XCTAssertEqual(row.paneStatusSymbolNamesForTesting, ["checkmark.circle.fill"])
    }

    func test_worklane_row_keeps_short_branch_trailing_for_single_pane_agent_rows() {
        let row = makeRow(width: 320, height: 110)

        row.configure(
            with: makeSummary(
                primaryText: "General coding assistance session",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "General coding assistance session",
                        trailingText: "main",
                        detailText: nil,
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    ),
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.primaryTextsForTesting, ["General coding assistance session"])
        XCTAssertEqual(row.primaryTrailingTextsForTesting, ["main"])
        XCTAssertEqual(row.detailTextsForTesting, [])
    }

    func test_worklane_row_spills_long_branch_into_detail_line_when_width_is_tight() {
        let row = makeRow(width: 220, height: 110)

        row.configure(
            with: makeSummary(
                primaryText: "Fix zsh startup",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Fix zsh startup",
                        trailingText: "feature/autoresearch/zsh-startup-2026-03-22",
                        detailText: nil,
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    ),
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.primaryTextsForTesting, ["Fix zsh startup"])
        XCTAssertEqual(row.primaryTrailingTextsForTesting, [])
        XCTAssertEqual(row.detailTextsForTesting, ["feature/autoresearch/zsh-startup-2026-03-22"])
    }

    func test_worklane_row_restores_long_branch_to_trailing_slot_after_growing_wider() {
        let row = makeRow(width: 220, height: 110)

        row.configure(
            with: makeSummary(
                primaryText: "Fix zsh startup",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Fix zsh startup",
                        trailingText: "feature/autoresearch/zsh-startup-2026-03-22",
                        detailText: nil,
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    ),
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.primaryTrailingTextsForTesting, [])
        XCTAssertEqual(row.detailTextsForTesting, ["feature/autoresearch/zsh-startup-2026-03-22"])

        row.frame.size.width = 720
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            row.primaryTrailingTextsForTesting,
            ["feature/autoresearch/zsh-startup-2026-03-22"]
        )
        XCTAssertEqual(row.detailTextsForTesting, [])
    }

    func test_worklane_row_does_not_accumulate_duplicate_width_constraints_across_resizes() {
        let row = makeRow(width: 220, height: 110)

        row.configure(
            with: makeSummary(
                primaryText: "Fix zsh startup",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Fix zsh startup",
                        trailingText: "feature/autoresearch/zsh-startup-2026-03-22",
                        detailText: nil,
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    ),
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.paneRowWidthConstraintCountForTesting, 1)

        row.frame.size.width = 260
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.paneRowWidthConstraintCountForTesting, 1)

        row.frame.size.width = 720
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.paneRowWidthConstraintCountForTesting, 1)
    }

    func test_worklane_row_deactivates_pane_width_constraints_when_switching_to_single_summary_layout() {
        let row = makeRow(width: 220, height: 110)

        row.configure(
            with: makeSummary(
                primaryText: "Fix zsh startup",
                paneRows: [
                    WorklaneSidebarPaneRow(
                        paneID: PaneID("worklane-main-agent"),
                        primaryText: "Fix zsh startup",
                        trailingText: "feature/autoresearch/zsh-startup-2026-03-22",
                        detailText: nil,
                        statusText: "Running",
                        attentionState: .running,
                        isFocused: true,
                        isWorking: true
                    ),
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.paneRowWidthConstraintCountForTesting, 1)

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

        XCTAssertEqual(row.paneRowWidthConstraintCountForTesting, 0)
    }

    func test_worklane_row_moves_primary_view_to_focused_pane_position() {
        let row = makeRow(height: 92)

        row.configure(
            with: makeSummary(
                primaryText: "k8s-zenjoy",
                focusedPaneLineIndex: 1,
                detailLines: [
                    WorklaneSidebarDetailLine(text: "feature/scaleway-transactional-mails", emphasis: .secondary),
                    WorklaneSidebarDetailLine(text: "Personal", emphasis: .secondary),
                ]
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.primaryRowIndexForTesting, 1)
        XCTAssertEqual(row.detailTextsForTesting, ["feature/scaleway-transactional-mails", "Personal"])
    }

    func test_working_worklane_row_uses_text_derived_shimmer_highlight() {
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

    func test_working_worklane_row_lifts_top_label_out_of_tertiary_text() {
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

    func test_worklane_row_ignores_legacy_sidebar_accessory_and_artifact_concepts() {
        let row = makeRow(height: 88)

        row.configure(
            with: makeSummary(
                primaryText: "Claude Code",
                statusText: "Needs input",
                detailLines: [
                    WorklaneSidebarDetailLine(text: "main • …/project", emphasis: .primary),
                ],
                attentionState: .needsInput
            ),
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.detailTextsForTesting, ["main • …/project"])
        XCTAssertEqual(row.statusTextForTesting, "Needs input")
    }

    func test_sidebar_view_uses_a_single_shared_shimmer_driver_for_visible_working_rows() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 220))
        let window = makeVisibleWindow(containing: sidebarView)

        sidebarView.render(
            summaries: [
                makeSidebarSummary(worklaneID: WorklaneID("worklane-api"), primaryText: "API"),
                makeSidebarSummary(
                    worklaneID: WorklaneID("worklane-web"),
                    primaryText: "Web",
                    isActive: false
                ),
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )
        sidebarView.layoutSubtreeIfNeeded()
        sidebarView.updateShimmerVisibilityForTesting()

        let buttons = try sidebarWorklaneButtons(in: sidebarView)
        XCTAssertEqual(buttons.count, 2)
        XCTAssertEqual(
            buttons[0].shimmerCoordinatorIdentifierForTesting,
            buttons[1].shimmerCoordinatorIdentifierForTesting
        )
        XCTAssertTrue(sidebarView.shimmerDriverIsRunningForTesting)
        XCTAssertTrue(buttons.allSatisfy(\.shimmerIsAnimatingForTesting))
        XCTAssertTrue(window.isVisible)
    }

    func test_sidebar_view_keeps_offscreen_working_rows_static() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 140))
        _ = makeVisibleWindow(containing: sidebarView)

        sidebarView.render(
            summaries: [
                makeSidebarSummary(worklaneID: WorklaneID("worklane-api"), primaryText: "API"),
                makeSidebarSummary(worklaneID: WorklaneID("worklane-web"), primaryText: "Web"),
                makeSidebarSummary(worklaneID: WorklaneID("worklane-cli"), primaryText: "CLI"),
                makeSidebarSummary(worklaneID: WorklaneID("worklane-docs"), primaryText: "Docs"),
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )
        sidebarView.layoutSubtreeIfNeeded()
        sidebarView.updateShimmerVisibilityForTesting()

        let buttons = try sidebarWorklaneButtons(in: sidebarView)
        XCTAssertEqual(buttons.count, 4)
        XCTAssertTrue(buttons[0].shimmerIsAnimatingForTesting)
        XCTAssertFalse(buttons.last?.shimmerIsAnimatingForTesting ?? true)
        XCTAssertTrue(sidebarView.shimmerDriverIsRunningForTesting)
    }

    func test_sidebar_view_pauses_shared_shimmer_driver_when_window_is_hidden() throws {
        let sidebarView = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 220))
        let window = makeVisibleWindow(containing: sidebarView)

        sidebarView.render(
            summaries: [
                makeSidebarSummary(worklaneID: WorklaneID("worklane-api"), primaryText: "API"),
            ],
            theme: ZenttyTheme.fallback(for: nil)
        )
        sidebarView.layoutSubtreeIfNeeded()
        sidebarView.updateShimmerVisibilityForTesting()

        XCTAssertTrue(sidebarView.shimmerDriverIsRunningForTesting)

        window.orderOut(nil)
        sidebarView.updateShimmerVisibilityForTesting()

        let buttons = try sidebarWorklaneButtons(in: sidebarView)
        XCTAssertFalse(sidebarView.shimmerDriverIsRunningForTesting)
        XCTAssertFalse(buttons.first?.shimmerIsAnimatingForTesting ?? true)
    }

    private func makeRow(width: CGFloat = 280, height: CGFloat = 72) -> SidebarWorklaneRowButton {
        let row = SidebarWorklaneRowButton(
            worklaneID: WorklaneID("worklane-main"),
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
        detailLines: [WorklaneSidebarDetailLine] = [],
        paneRows: [WorklaneSidebarPaneRow] = [],
        attentionState: WorklaneAttentionState? = nil,
        interactionKind: PaneInteractionKind? = nil,
        interactionLabel: String? = nil,
        interactionSymbolName: String? = nil,
        isWorking: Bool = false,
        isActive: Bool = false
    ) -> WorklaneSidebarSummary {
        WorklaneSidebarSummary(
            worklaneID: WorklaneID("worklane-main"),
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

    private func makeSidebarSummary(
        worklaneID: WorklaneID,
        primaryText: String,
        isActive: Bool = false
    ) -> WorklaneSidebarSummary {
        WorklaneSidebarSummary(
            worklaneID: worklaneID,
            badgeText: "1",
            topLabel: nil,
            primaryText: primaryText,
            statusText: "Running",
            detailLines: [],
            attentionState: .running,
            isWorking: true,
            isActive: isActive
        )
    }

    private func makeVisibleWindow(containing sidebarView: SidebarView) -> NSWindow {
        let window = NSWindow(
            contentRect: sidebarView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = sidebarView
        window.orderFrontRegardless()
        return window
    }

    private func sidebarWorklaneButtons(in sidebarView: SidebarView) throws -> [SidebarWorklaneRowButton] {
        try sidebarView.worklaneButtonsForTesting.map { button in
            try XCTUnwrap(button as? SidebarWorklaneRowButton)
        }
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
