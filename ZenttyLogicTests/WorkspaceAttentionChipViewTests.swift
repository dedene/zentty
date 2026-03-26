import AppKit
import XCTest
@testable import Zentty

@MainActor
final class WorkspaceAttentionChipViewTests: XCTestCase {
    func test_attention_chip_keeps_broad_status_text_while_using_split_interaction_symbol() {
        let chip = WorkspaceAttentionChipView(frame: .zero)
        chip.apply(theme: ZenttyTheme.fallback(for: nil), animated: false)

        chip.render(
            presentation: WorkspaceAttentionChipPresentation(
                statusText: "Needs input",
                toolText: "Claude Code",
                artifactLabel: nil,
                artifactURL: nil,
                interactionKind: .question
            )
        )

        XCTAssertEqual(chip.stateTextForTesting, "Needs input")
        XCTAssertEqual(chip.stateSymbolNameForTesting, "questionmark.circle")
        XCTAssertEqual(chip.toolTextForTesting, "Claude Code")
    }

    func test_attention_chip_keeps_text_only_fallback_when_interaction_metadata_is_missing() {
        let chip = WorkspaceAttentionChipView(frame: .zero)
        chip.apply(theme: ZenttyTheme.fallback(for: nil), animated: false)

        chip.render(
            presentation: WorkspaceAttentionChipPresentation(
                statusText: "Running",
                toolText: "Claude Code",
                artifactLabel: nil,
                artifactURL: nil
            )
        )

        XCTAssertEqual(chip.stateTextForTesting, "Running")
        XCTAssertEqual(chip.stateSymbolNameForTesting, "")
    }
}
