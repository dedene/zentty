import AppKit
import XCTest
@testable import Zentty

@MainActor
final class PaneInputServiceTests: XCTestCase {
    // MARK: - Send guard

    func test_guard_refuses_running_agent_unless_forced() {
        let running = PaneSendGuard.AgentActivity(agent: "Claude Code", phase: .running)
        XCTAssertEqual(PaneSendGuard.decision(for: running, force: false), .refuseMidTurn(agent: "Claude Code"))
        XCTAssertEqual(PaneSendGuard.decision(for: running, force: true), .allow)
    }

    func test_guard_refuses_prompts_that_input_could_answer() {
        for interaction in [PaneInteractionKind.approval, .decision, .auth] {
            let activity = PaneSendGuard.AgentActivity(agent: "Codex", phase: .needsInput, interaction: interaction)
            XCTAssertEqual(
                PaneSendGuard.decision(for: activity, force: false),
                .refusePrompt(agent: "Codex", interaction: interaction),
                interaction.rawValue
            )
            XCTAssertEqual(PaneSendGuard.decision(for: activity, force: true), .allow, interaction.rawValue)
        }
    }

    func test_guard_allows_questions_plain_input_idle_and_plain_panes() {
        for interaction in [PaneInteractionKind.question, .genericInput, nil] {
            let activity = PaneSendGuard.AgentActivity(agent: "Codex", phase: .needsInput, interaction: interaction)
            XCTAssertEqual(PaneSendGuard.decision(for: activity, force: false), .allow, "\(String(describing: interaction))")
        }
        for phase in [PanePresentationPhase.idle, .starting, .unresolvedStop] {
            let activity = PaneSendGuard.AgentActivity(agent: "Codex", phase: phase)
            XCTAssertEqual(PaneSendGuard.decision(for: activity, force: false), .allow, "\(phase)")
        }
        XCTAssertEqual(PaneSendGuard.decision(for: nil, force: false), .allow)
    }

    func test_key_guard_always_lets_interrupts_through() {
        let approval = PaneSendGuard.AgentActivity(agent: "Claude Code", phase: .needsInput, interaction: .approval)
        let running = PaneSendGuard.AgentActivity(agent: "Claude Code", phase: .running)
        for activity in [approval, running] {
            XCTAssertEqual(PaneSendGuard.decision(forKeys: [.control("c")], activity: activity, force: false), .allow)
            XCTAssertEqual(
                PaneSendGuard.decision(forKeys: [.key(.escape, shift: false), .control("c")], activity: activity, force: false),
                .allow
            )
        }
    }

    func test_key_guard_refuses_answering_keys_unless_forced() {
        let approval = PaneSendGuard.AgentActivity(agent: "Claude Code", phase: .needsInput, interaction: .approval)
        for strokes: [PaneKeyStroke] in [[.text("y")], [.key(.enter, shift: false)], [.control("c"), .key(.enter, shift: false)]] {
            XCTAssertEqual(
                PaneSendGuard.decision(forKeys: strokes, activity: approval, force: false),
                .refusePrompt(agent: "Claude Code", interaction: .approval)
            )
            XCTAssertEqual(PaneSendGuard.decision(forKeys: strokes, activity: approval, force: true), .allow)
        }
        let running = PaneSendGuard.AgentActivity(agent: "Codex", phase: .running)
        XCTAssertEqual(
            PaneSendGuard.decision(forKeys: [.key(.up, shift: false)], activity: running, force: false),
            .refuseMidTurn(agent: "Codex")
        )
    }

    func test_refusals_map_to_errors_that_name_agent_and_force_flag() throws {
        XCTAssertNil(PaneSendGuard.Decision.allow.refusalError)
        let busy = try XCTUnwrap(PaneSendGuard.Decision.refuseMidTurn(agent: "Codex").refusalError)
        XCTAssertEqual(busy, .agentBusy(agent: "Codex"))
        let prompt = try XCTUnwrap(
            PaneSendGuard.Decision.refusePrompt(agent: "Codex", interaction: .approval).refusalError
        )
        XCTAssertEqual(prompt, .agentPrompting(agent: "Codex", interaction: "approval"))
        for message in [busy.localizedDescription, prompt.localizedDescription] {
            XCTAssertTrue(message.contains("Codex"), message)
            XCTAssertTrue(message.contains("--force"), message)
        }
    }

    // MARK: - Delivery mode

    func test_single_line_text_is_typed_unless_paste_is_asked_for() {
        XCTAssertEqual(PaneSendDelivery.mode(for: "npm test", pasteRequested: false), .type)
        XCTAssertEqual(PaneSendDelivery.mode(for: "npm test", pasteRequested: true), .paste)
    }

    func test_multi_line_text_is_always_pasted() {
        for text in ["ls\nrm -rf build", "a\r\nb", "a\rb", "trailing\n"] {
            XCTAssertEqual(PaneSendDelivery.mode(for: text, pasteRequested: false), .paste, text.debugDescription)
        }
    }

    // MARK: - Delivery

    func test_no_runtime_delivers_nothing() {
        XCTAssertFalse(PaneInputService.type("x", into: nil))
        XCTAssertFalse(PaneInputService.paste("x", into: nil))
        XCTAssertFalse(PaneInputService.press([.key(.enter, shift: false)], into: nil))
    }

    func test_runtime_without_a_surface_reports_failure_and_sends_nothing() {
        let adapter = RecordingInputAdapter()
        adapter.acceptsInput = false
        adapter.typeResult = false
        adapter.keyResult = false

        XCTAssertFalse(PaneInputService.type("npm test", into: adapter))
        XCTAssertFalse(PaneInputService.paste("npm test", into: adapter))
        XCTAssertFalse(PaneInputService.press([.key(.enter, shift: false)], into: adapter))
        XCTAssertEqual(adapter.pastedText, [])
    }

    func test_typed_text_never_falls_back_to_paste() {
        let adapter = RecordingInputAdapter()
        adapter.typeResult = false
        XCTAssertFalse(PaneInputService.type("npm test", into: adapter))
        XCTAssertEqual(adapter.typedText, ["npm test"])
        XCTAssertEqual(adapter.pastedText, [])
    }

    func test_key_the_encoder_passes_on_is_typed_as_bytes_not_pasted() {
        let adapter = RecordingInputAdapter()
        adapter.keyResult = false
        XCTAssertTrue(PaneInputService.press([.key(.up, shift: false)], into: adapter))
        XCTAssertEqual(adapter.pressedStrokes, [.key(.up, shift: false)])
        XCTAssertEqual(adapter.typedText, ["\u{1b}[A"])
        XCTAssertEqual(adapter.pastedText, [])
    }

    func test_live_surface_takes_typed_text_keys_and_paste() {
        let adapter = RecordingInputAdapter()
        XCTAssertTrue(PaneInputService.type("echo hi", into: adapter))
        XCTAssertTrue(PaneInputService.press([.control("c"), .key(.enter, shift: false)], into: adapter))
        XCTAssertTrue(PaneInputService.paste("a\nb", into: adapter))
        XCTAssertEqual(adapter.typedText, ["echo hi"])
        XCTAssertEqual(adapter.pressedStrokes, [.control("c"), .key(.enter, shift: false)])
        XCTAssertEqual(adapter.pastedText, ["a\nb"])
    }
}

@MainActor
private final class RecordingInputAdapter: TerminalAdapter, TerminalPaneInputDriving {
    var acceptsInput = true
    var typeResult = true
    var keyResult = true
    private(set) var typedText: [String] = []
    private(set) var pressedStrokes: [PaneKeyStroke] = []
    private(set) var pastedText: [String] = []

    var hasScrollback: Bool { false }
    var cellWidth: CGFloat { 8 }
    var cellHeight: CGFloat { 16 }
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?
    var terminalGridSize: TerminalGridSize? { nil }

    func makeTerminalView() -> NSView { NSView() }
    func startSession(using request: TerminalSessionRequest) throws {}
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}
    func close() {}

    func sendText(_ text: String) {
        pastedText.append(text)
    }

    func typeText(_ text: String) -> Bool {
        typedText.append(text)
        return acceptsInput && typeResult
    }

    func sendKeyStroke(_ stroke: PaneKeyStroke) -> Bool {
        pressedStrokes.append(stroke)
        return acceptsInput && keyResult
    }
}
