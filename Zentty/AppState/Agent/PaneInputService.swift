import Foundation

/// Scripted input and screen reads for panes. Shared by the `zentty pane
/// send|send-key|read` commands and the agent-teams shim
/// (`TmuxCompatIPCHandler`), so both drive the terminal the same way.
///
/// Every delivery reports whether the bytes reached a live terminal. A pane
/// whose runtime exists but whose surface has not started yet (staggered
/// restore) or has already closed reports false, so callers can fail loudly
/// instead of claiming success for input that went nowhere.
@MainActor
enum PaneInputService {
    /// Paste-style delivery (`ghostty_surface_text`): bracketed when the
    /// program in the pane enabled bracketed paste.
    @discardableResult
    static func pasteText(_ text: String, to paneID: PaneID, in controller: MainWindowController) -> Bool {
        paste(text, into: controller.terminalAdapter(for: paneID))
    }

    /// Typed delivery: the bytes go to the terminal as if typed, never
    /// paste-wrapped.
    @discardableResult
    static func typeText(_ text: String, to paneID: PaneID, in controller: MainWindowController) -> Bool {
        type(text, into: controller.terminalAdapter(for: paneID))
    }

    @discardableResult
    static func sendKeyStrokes(_ strokes: [PaneKeyStroke], to paneID: PaneID, in controller: MainWindowController) -> Bool {
        press(strokes, into: controller.terminalAdapter(for: paneID))
    }

    static func paste(_ text: String, into adapter: (any TerminalAdapter)?) -> Bool {
        guard let adapter else {
            return false
        }
        if let driver = adapter as? TerminalPaneInputDriving, !driver.acceptsInput {
            return false
        }
        adapter.sendText(text)
        return true
    }

    static func type(_ text: String, into adapter: (any TerminalAdapter)?) -> Bool {
        guard let adapter else {
            return false
        }
        guard let driver = adapter as? TerminalPaneInputDriving else {
            // Adapters without a typed path only have paste-style delivery.
            adapter.sendText(text)
            return true
        }
        return driver.typeText(text)
    }

    static func press(_ strokes: [PaneKeyStroke], into adapter: (any TerminalAdapter)?) -> Bool {
        guard let adapter else {
            return false
        }
        guard let driver = adapter as? TerminalPaneInputDriving else {
            adapter.sendText(strokes.map(\.legacyText).joined())
            return true
        }
        guard driver.acceptsInput else {
            return false
        }
        for stroke in strokes {
            // A key the encoder passes on is typed as its plain bytes, never
            // pasted: paste wrapping would turn a keystroke into text.
            if !driver.sendKeyStroke(stroke), !driver.typeText(stroke.legacyText) {
                return false
            }
        }
        return true
    }

    static func readText(
        from paneID: PaneID,
        in controller: MainWindowController,
        includeScrollback: Bool,
        lineLimit: Int?
    ) -> String? {
        controller.readText(from: paneID, includeScrollback: includeScrollback, lineLimit: lineLimit)
    }

    static func gridSize(of paneID: PaneID, in controller: MainWindowController) -> TerminalGridSize? {
        (controller.terminalAdapter(for: paneID) as? TerminalPaneInputDriving)?.terminalGridSize
    }

    /// The agent the pane is hosting, its phase, and what it is asking for.
    static func agentActivity(
        of paneID: PaneID,
        in worklaneID: WorklaneID,
        controller: MainWindowController
    ) -> PaneSendGuard.AgentActivity? {
        guard let presentation = controller.worklaneStore.worklanes
            .first(where: { $0.id == worklaneID })?
            .auxiliaryStateByPaneID[paneID]?
            .presentation,
            let tool = presentation.recognizedTool
        else {
            return nil
        }
        return PaneSendGuard.AgentActivity(
            agent: tool.displayName,
            phase: presentation.runtimePhase,
            interaction: presentation.runtimePhase == .needsInput ? presentation.interactionKind : nil
        )
    }
}

/// Decides whether scripted input may reach a pane that hosts an agent.
///
/// Typing into an agent that is mid-turn would interleave with whatever it
/// is doing. Typing into an approval, decision, or sign-in prompt is worse:
/// characters can act as menu hotkeys and Enter confirms the highlighted
/// option, so a script could approve something the user never saw. Both
/// are refused unless forced. Questions and plain input prompts are what
/// scripted input is for, so they pass.
enum PaneSendGuard {
    struct AgentActivity: Equatable, Sendable {
        let agent: String
        let phase: PanePresentationPhase
        var interaction: PaneInteractionKind? = nil
    }

    enum Decision: Equatable {
        case allow
        case refuseMidTurn(agent: String)
        case refusePrompt(agent: String, interaction: PaneInteractionKind)
    }

    static func decision(for activity: AgentActivity?, force: Bool) -> Decision {
        guard !force, let activity else {
            return .allow
        }
        switch activity.phase {
        case .running:
            return .refuseMidTurn(agent: activity.agent)
        case .needsInput:
            guard let interaction = activity.interaction, answersPrompt(interaction) else {
                return .allow
            }
            return .refusePrompt(agent: activity.agent, interaction: interaction)
        case .idle, .starting, .unresolvedStop:
            return .allow
        }
    }

    /// `send-key` follows the same rule, except that interrupting always
    /// works: Ctrl-C and Escape only ever stop or dismiss.
    static func decision(forKeys strokes: [PaneKeyStroke], activity: AgentActivity?, force: Bool) -> Decision {
        if !strokes.isEmpty, strokes.allSatisfy(isInterrupt) {
            return .allow
        }
        return decision(for: activity, force: force)
    }

    static func isInterrupt(_ stroke: PaneKeyStroke) -> Bool {
        stroke == .control("c") || stroke == .key(.escape, shift: false)
    }

    private static func answersPrompt(_ interaction: PaneInteractionKind) -> Bool {
        switch interaction {
        case .approval, .decision, .auth:
            return true
        case .question, .genericInput:
            return false
        }
    }
}

extension PaneSendGuard.Decision {
    /// The error to report for a refusal, or nil when input may go through.
    var refusalError: PaneControlIPCError? {
        switch self {
        case .allow:
            nil
        case .refuseMidTurn(let agent):
            .agentBusy(agent: agent)
        case .refusePrompt(let agent, let interaction):
            .agentPrompting(agent: agent, interaction: interaction.rawValue)
        }
    }
}

/// How `pane send` delivers its text.
enum PaneSendDelivery: Equatable {
    case type
    case paste

    /// Multi-line text always goes as one paste. Typed, a shell would run
    /// each line the moment its newline arrived.
    static func mode(for text: String, pasteRequested: Bool) -> PaneSendDelivery {
        pasteRequested || text.contains(where: \.isNewline) ? .paste : .type
    }
}

enum PaneTextLines {
    /// Keeps the last `maxLines` lines of `text`, preserving a trailing newline.
    static func tail(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else {
            return ""
        }
        let hadTrailingNewline = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hadTrailingNewline, lines.last == "" {
            lines.removeLast()
        }
        var output = lines.suffix(maxLines).joined(separator: "\n")
        if hadTrailingNewline, !output.isEmpty {
            output.append("\n")
        }
        return output
    }
}
