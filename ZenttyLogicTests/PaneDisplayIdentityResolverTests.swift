import XCTest
@testable import Zentty

final class PaneDisplayIdentityResolverTests: XCTestCase {
    func test_primaryLabel_prefers_custom_title_over_cwd_and_remembered_title() {
        let pane = PaneState(id: PaneID("pn_a"), title: "shell", customTitle: "Nimbu API")
        let presentation = PanePresentationState(
            cwd: "/Users/peter/proj/nimbu",
            branchDisplayText: "main",
            identityText: "nimbu",
            contextText: "main · nimbu",
            rememberedTitle: "Improve command palette"
        )

        XCTAssertEqual(
            PaneDisplayIdentityResolver.primaryLabel(pane: pane, presentation: presentation, metadata: nil),
            "Nimbu API"
        )
    }

    func test_primaryLabel_custom_title_wins_over_volatile_agent_title() {
        let pane = PaneState(id: PaneID("pn_a"), title: "shell", customTitle: "Nimbu API")
        let presentation = PanePresentationState(
            rememberedTitle: "Improve command palette",
            recognizedTool: .codex
        )
        let metadata = TerminalMetadata(title: "Working... (5s) · my-project")

        XCTAssertEqual(
            PaneDisplayIdentityResolver.primaryLabel(pane: pane, presentation: presentation, metadata: metadata),
            "Nimbu API"
        )
    }

    func test_primaryLabel_custom_title_wins_over_inferred_ssh_label() {
        let pane = PaneState(id: PaneID("pn_a"), title: "shell", customTitle: "Nimbu API")
        let presentation = PanePresentationState(
            cwd: "/srv/nimbu",
            sshConnectionLabel: "deploy@api.example.com"
        )

        XCTAssertEqual(
            PaneDisplayIdentityResolver.primaryLabel(pane: pane, presentation: presentation, metadata: nil),
            "Nimbu API"
        )
    }

    func test_borderLabelText_uses_custom_title() {
        let pane = PaneState(id: PaneID("pn_a"), title: "shell", customTitle: "Nimbu API")
        let presentation = PanePresentationState(cwd: "/Users/peter/proj/nimbu")

        XCTAssertEqual(
            PaneDisplayIdentityResolver.borderLabelText(pane: pane, presentation: presentation),
            "Nimbu API"
        )
    }

    func test_hasCustomTitle_is_false_when_cleared() {
        let pane = PaneState(id: PaneID("pn_a"), title: "shell", customTitle: nil)
        XCTAssertFalse(PaneDisplayIdentityResolver.hasCustomTitle(for: pane))
    }
}
