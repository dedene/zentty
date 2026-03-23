import AppKit
import XCTest
@testable import Zentty

@MainActor
final class SidebarWorkspaceRowButtonTests: XCTestCase {
    func test_working_workspace_row_starts_shimmer_animation() {
        let row = SidebarWorkspaceRowButton(
            workspaceID: WorkspaceID("workspace-main"),
            reducedMotionProvider: { false }
        )
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 72)

        row.configure(
            with: WorkspaceSidebarSummary(
                workspaceID: WorkspaceID("workspace-main"),
                badgeText: "1",
                primaryText: "project",
                statusText: "Claude Code is working",
                stateBadgeText: "Running",
                detailLines: [
                    WorkspaceSidebarDetailLine(text: "feature/sidebar • project", emphasis: .primary)
                ],
                overflowText: nil,
                leadingAccessory: .agent(.claudeCode),
                attentionState: .running,
                artifactLink: nil,
                isWorking: true,
                isActive: false
            ),
            reservesLeadingAccessoryGutter: true,
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertTrue(row.isWorkingForTesting)
        XCTAssertTrue(row.shimmerIsAnimatingForTesting)
    }

    func test_idle_workspace_row_stops_existing_shimmer_animation() {
        let row = SidebarWorkspaceRowButton(
            workspaceID: WorkspaceID("workspace-main"),
            reducedMotionProvider: { false }
        )
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 72)

        row.configure(
            with: WorkspaceSidebarSummary(
                workspaceID: WorkspaceID("workspace-main"),
                badgeText: "1",
                primaryText: "project",
                statusText: "Claude Code is working",
                stateBadgeText: "Running",
                detailLines: [],
                overflowText: nil,
                leadingAccessory: .agent(.claudeCode),
                attentionState: .running,
                artifactLink: nil,
                isWorking: true,
                isActive: false
            ),
            reservesLeadingAccessoryGutter: true,
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )
        XCTAssertTrue(row.shimmerIsAnimatingForTesting)

        row.configure(
            with: WorkspaceSidebarSummary(
                workspaceID: WorkspaceID("workspace-main"),
                badgeText: "1",
                primaryText: "project",
                statusText: nil,
                detailLines: [],
                overflowText: nil,
                leadingAccessory: .agent(.claudeCode),
                attentionState: nil,
                artifactLink: nil,
                isWorking: false,
                isActive: false
            ),
            reservesLeadingAccessoryGutter: true,
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertFalse(row.isWorkingForTesting)
        XCTAssertFalse(row.shimmerIsAnimatingForTesting)
    }

    func test_working_active_workspace_row_uses_distinct_background_tint() {
        let row = SidebarWorkspaceRowButton(
            workspaceID: WorkspaceID("workspace-main"),
            reducedMotionProvider: { false }
        )
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 72)
        let theme = ZenttyTheme.fallback(for: nil)

        row.configure(
            with: WorkspaceSidebarSummary(
                workspaceID: WorkspaceID("workspace-main"),
                badgeText: "1",
                primaryText: "project",
                statusText: nil,
                detailLines: [],
                overflowText: nil,
                leadingAccessory: .agent(.claudeCode),
                attentionState: nil,
                artifactLink: nil,
                isWorking: false,
                isActive: true
            ),
            reservesLeadingAccessoryGutter: true,
            theme: theme,
            animated: false
        )
        let idleBackground = try! XCTUnwrap(row.backgroundColorForTesting?.usingColorSpace(.deviceRGB))

        row.configure(
            with: WorkspaceSidebarSummary(
                workspaceID: WorkspaceID("workspace-main"),
                badgeText: "1",
                primaryText: "project",
                statusText: "Claude Code is working",
                stateBadgeText: "Running",
                detailLines: [],
                overflowText: nil,
                leadingAccessory: .agent(.claudeCode),
                attentionState: .running,
                artifactLink: nil,
                isWorking: true,
                isActive: true
            ),
            reservesLeadingAccessoryGutter: true,
            theme: theme,
            animated: false
        )
        let workingBackground = try! XCTUnwrap(row.backgroundColorForTesting?.usingColorSpace(.deviceRGB))

        XCTAssertGreaterThan(abs(idleBackground.redComponent - workingBackground.redComponent), 0.001)
        XCTAssertGreaterThan(abs(idleBackground.greenComponent - workingBackground.greenComponent), 0.001)
        XCTAssertTrue(row.shimmerIsAnimatingForTesting)
    }

    func test_workspace_row_exposes_explicit_status_copy_and_state_badge() {
        let row = SidebarWorkspaceRowButton(
            workspaceID: WorkspaceID("workspace-main"),
            reducedMotionProvider: { false }
        )
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 88)

        row.configure(
            with: WorkspaceSidebarSummary(
                workspaceID: WorkspaceID("workspace-main"),
                badgeText: "1",
                primaryText: "project",
                statusText: "Claude Code is waiting for your input",
                stateBadgeText: "Needs input",
                detailLines: [
                    WorkspaceSidebarDetailLine(text: "feature/sidebar • project", emphasis: .primary)
                ],
                overflowText: nil,
                leadingAccessory: .agent(.claudeCode),
                attentionState: .needsInput,
                artifactLink: nil,
                isWorking: false,
                isActive: false
            ),
            reservesLeadingAccessoryGutter: true,
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.statusTextForTesting, "Claude Code is waiting for your input")
        XCTAssertEqual(row.stateBadgeTextForTesting, "Needs input")
    }

    func test_workspace_row_moves_primary_view_to_focused_pane_position() {
        let row = SidebarWorkspaceRowButton(
            workspaceID: WorkspaceID("workspace-main"),
            reducedMotionProvider: { false }
        )
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 92)

        row.configure(
            with: WorkspaceSidebarSummary(
                workspaceID: WorkspaceID("workspace-main"),
                badgeText: "1",
                primaryText: "k8s-zenjoy",
                focusedPaneLineIndex: 1,
                detailLines: [
                    WorkspaceSidebarDetailLine(text: "feature/scaleway-transactional-mails", emphasis: .secondary),
                    WorkspaceSidebarDetailLine(text: "Personal", emphasis: .secondary),
                ],
                overflowText: nil,
                leadingAccessory: nil,
                attentionState: nil,
                artifactLink: nil,
                isWorking: false,
                isActive: false
            ),
            reservesLeadingAccessoryGutter: false,
            theme: ZenttyTheme.fallback(for: nil),
            animated: false
        )

        XCTAssertEqual(row.primaryRowIndexForTesting, 1)
        XCTAssertEqual(row.detailTextsForTesting, ["feature/scaleway-transactional-mails", "Personal"])
    }

    func test_working_workspace_row_uses_text_derived_shimmer_highlight() {
        let row = SidebarWorkspaceRowButton(
            workspaceID: WorkspaceID("workspace-main"),
            reducedMotionProvider: { false }
        )
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 72)
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.9,
                backgroundBlurRadius: 25
            )
        )

        row.configure(
            with: WorkspaceSidebarSummary(
                workspaceID: WorkspaceID("workspace-main"),
                badgeText: "1",
                primaryText: "project",
                statusText: "Claude Code is working",
                stateBadgeText: "Running",
                detailLines: [],
                overflowText: nil,
                leadingAccessory: .agent(.claudeCode),
                attentionState: .running,
                artifactLink: nil,
                isWorking: true,
                isActive: false
            ),
            reservesLeadingAccessoryGutter: true,
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
        let row = SidebarWorkspaceRowButton(
            workspaceID: WorkspaceID("workspace-main"),
            reducedMotionProvider: { false }
        )
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 72)
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.9,
                backgroundBlurRadius: 25
            )
        )

        row.configure(
            with: WorkspaceSidebarSummary(
                workspaceID: WorkspaceID("workspace-main"),
                badgeText: "1",
                topLabel: "peter@m1-pro-peter:~",
                primaryText: "peter@m1-pro-peter:~/Development/...",
                statusText: "Claude Code is working",
                stateBadgeText: "Running",
                detailLines: [],
                overflowText: nil,
                leadingAccessory: .agent(.claudeCode),
                attentionState: .running,
                artifactLink: nil,
                isWorking: true,
                isActive: false
            ),
            reservesLeadingAccessoryGutter: true,
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
        let row = SidebarWorkspaceRowButton(
            workspaceID: WorkspaceID("workspace-main"),
            reducedMotionProvider: { false }
        )
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 72)
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#101418")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.9,
                backgroundBlurRadius: 25
            )
        )

        row.configure(
            with: WorkspaceSidebarSummary(
                workspaceID: WorkspaceID("workspace-main"),
                badgeText: "1",
                topLabel: "peter@m1-pro-peter:~",
                primaryText: "peter@m1-pro-peter:~/Development/Zentty",
                statusText: nil,
                detailLines: [],
                overflowText: nil,
                leadingAccessory: .agent(.claudeCode),
                attentionState: nil,
                artifactLink: nil,
                isWorking: false,
                isActive: false
            ),
            reservesLeadingAccessoryGutter: true,
            theme: theme,
            animated: false
        )

        XCTAssertGreaterThan(row.primaryTextColorForTesting.perceivedLuminance, theme.sidebarBackground.perceivedLuminance)
        XCTAssertGreaterThan(row.topLabelColorForTesting.perceivedLuminance, theme.sidebarBackground.perceivedLuminance)
        XCTAssertGreaterThan(row.primaryTextColorForTesting.contrastRatio(against: theme.sidebarBackground), 4.5)
    }

    func test_dark_sidebar_theme_forces_dark_row_appearance() {
        let row = SidebarWorkspaceRowButton(
            workspaceID: WorkspaceID("workspace-main"),
            reducedMotionProvider: { false }
        )
        row.appearance = NSAppearance(named: .aqua)
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 72)
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 0.9,
                backgroundBlurRadius: 25
            )
        )

        row.configure(
            with: WorkspaceSidebarSummary(
                workspaceID: WorkspaceID("workspace-main"),
                badgeText: "1",
                topLabel: "peter@m1-pro-peter:~",
                primaryText: "~",
                statusText: nil,
                detailLines: [],
                overflowText: nil,
                leadingAccessory: .agent(.claudeCode),
                attentionState: nil,
                artifactLink: nil,
                isWorking: false,
                isActive: false
            ),
            reservesLeadingAccessoryGutter: true,
            theme: theme,
            animated: false
        )

        XCTAssertEqual(row.appearanceMatchForTesting, .darkAqua)
    }

    func test_sidebar_row_disables_vibrancy() {
        let row = SidebarWorkspaceRowButton(
            workspaceID: WorkspaceID("workspace-main"),
            reducedMotionProvider: { false }
        )

        XCTAssertFalse(row.allowsVibrancy)
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
