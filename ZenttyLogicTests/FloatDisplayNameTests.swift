import XCTest
@testable import Zentty

final class FloatDisplayNameTests: XCTestCase {
    func test_custom_title_wins() {
        let pane = PaneState(id: PaneID("p"), title: "zsh", customTitle: "pnpm dev")
        var presentation = PanePresentationState()
        presentation.rememberedTitle = "Implement notifications"

        XCTAssertEqual(
            FloatDisplayName.resolve(pane: pane, presentation: presentation, metadata: nil),
            "pnpm dev"
        )
    }

    func test_custom_title_without_presentation() {
        let pane = PaneState(id: PaneID("p"), title: "zsh", customTitle: "  logs  ")

        XCTAssertEqual(FloatDisplayName.resolve(pane: pane, presentation: nil, metadata: nil), "logs")
    }

    func test_live_agent_title() {
        let pane = PaneState(id: PaneID("p"), title: "hermes")
        var presentation = PanePresentationState()
        presentation.recognizedTool = .hermes
        presentation.rememberedTitle = "Older title"
        let metadata = TerminalMetadata(title: "⏳ grok-4.3 · 19.9K/1M · 2%")

        XCTAssertEqual(
            FloatDisplayName.resolve(pane: pane, presentation: presentation, metadata: metadata),
            "⏳ grok-4.3 · 19.9K/1M · 2%"
        )
    }

    func test_remembered_title() {
        let pane = PaneState(id: PaneID("p"), title: "zsh")
        var presentation = PanePresentationState()
        presentation.rememberedTitle = "Implement notifications"

        XCTAssertEqual(
            FloatDisplayName.resolve(pane: pane, presentation: presentation, metadata: nil),
            "Implement notifications"
        )
    }

    func test_nothing_is_nil() {
        let pane = PaneState(id: PaneID("p"), title: "zsh")

        XCTAssertNil(FloatDisplayName.resolve(pane: pane, presentation: PanePresentationState(), metadata: nil))
        XCTAssertNil(FloatDisplayName.resolve(pane: pane, presentation: nil, metadata: nil))
    }
}
