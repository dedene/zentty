import AppKit
import XCTest
@testable import Zentty

@MainActor
final class WorklaneAttentionChipViewTests: XCTestCase {
    func test_attention_chip_keeps_broad_status_text_while_using_split_interaction_symbol() {
        let chip = WorklaneAttentionChipView(frame: .zero)
        chip.apply(theme: ZenttyTheme.fallback(for: nil), animated: false)

        chip.render(
            presentation: WorklaneAttentionChipPresentation(
                statusText: "Needs decision",
                toolText: "Claude Code",
                artifactLabel: nil,
                artifactURL: nil,
                interactionKind: .question
            )
        )

        XCTAssertEqual(chip.stateTextForTesting, "Needs decision")
        XCTAssertEqual(chip.stateSymbolNameForTesting, "list.bullet")
        XCTAssertEqual(chip.toolTextForTesting, "Claude Code")
    }

    func test_attention_chip_keeps_text_only_fallback_when_interaction_metadata_is_missing() {
        let chip = WorklaneAttentionChipView(frame: .zero)
        chip.apply(theme: ZenttyTheme.fallback(for: nil), animated: false)

        chip.render(
            presentation: WorklaneAttentionChipPresentation(
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
