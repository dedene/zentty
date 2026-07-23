import Foundation
import OSLog

private let companionInputLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CompanionInput")

// MARK: - Input sink seam

/// The single injection primitive the router needs: write bytes to a pane's live
/// terminal. Implemented by `AppDelegate` (resolve pane → `sendText`); faked in
/// tests. Returns `false` when the pane is unknown or has no live runtime.
@MainActor
protocol CompanionInputSink: AnyObject {
    func companionSendText(_ text: String, toPaneId paneId: String) -> Bool
}

// MARK: - Router

/// Turns `input.text` / `input.key` / `input.quickAction` messages into terminal
/// byte injections on the resolved pane, and produces the correlated
/// `input.ack`. `@MainActor` because injection touches the runtime graph.
@MainActor
final class CompanionInputRouter {
    private weak var sink: CompanionInputSink?

    init(sink: CompanionInputSink) {
        self.sink = sink
    }

    /// Handles an input-family message. Returns the ack payload the session
    /// sends back (correlated to the request via the envelope `replyTo`), or
    /// `nil` for a message this router does not own.
    func handle(_ message: CompanionMessage) -> CompanionInputAck? {
        switch message {
        case .inputText(let payload):
            return inject(payload.text, into: payload.paneId)
        case .inputKey(let payload):
            return inject(Self.bytes(for: payload.key), into: payload.paneId)
        case .inputQuickAction(let payload):
            guard let text = Self.bytes(forQuickAction: payload.actionId) else {
                return CompanionInputAck(ok: false, error: "unknown_action")
            }
            return inject(text, into: payload.paneId)
        default:
            return nil
        }
    }

    private func inject(_ text: String, into paneId: String) -> CompanionInputAck {
        guard let sink else {
            return CompanionInputAck(ok: false, error: "unavailable")
        }
        let ok = sink.companionSendText(text, toPaneId: paneId)
        return CompanionInputAck(ok: ok, error: ok ? nil : "pane_not_found")
    }

    // MARK: Key mapping

    /// Named keys → terminal bytes, mirroring the tmux special-key mapping used
    /// by `TmuxCompatIPCHandler` so the phone and `tmux send-keys` agree. This is
    /// the single control-key entry point for the companion: like the tmux path,
    /// it routes every key through `CompanionInputSink.companionSendText` (raw
    /// bytes into the pty) rather than synthesizing `NSEvent`s, so no public
    /// `submitControlKey` on the surface is needed.
    ///
    /// Arrows emit the standard CSI ("normal cursor key") sequences. libghostty
    /// exposes no API to read a surface's DECCKM (application-cursor-key) mode, so
    /// the bridge cannot switch to the `ESC O` form when a full-screen app has
    /// enabled it. In practice TUIs that request application mode also accept the
    /// normal CSI arrows, so this is a safe default rather than a correctness gap.
    static func bytes(for key: CompanionInputKey) -> String {
        switch key {
        case .enter: return "\r"
        case .escape: return "\u{1b}"
        case .tab: return "\t"
        case .up: return "\u{1b}[A"
        case .down: return "\u{1b}[B"
        case .right: return "\u{1b}[C"
        case .left: return "\u{1b}[D"
        case .ctrlC: return "\u{03}"
        case .ctrlD: return "\u{04}"
        case .ctrlZ: return "\u{1a}"
        case .ctrlR: return "\u{12}"
        }
    }

    /// Quick-action id → terminal bytes.
    ///
    /// v1 is deliberately coarse: without the pane's current prompt shape the
    /// bridge cannot know which numbered option "approve" maps to, so it sends
    /// the safe defaults — Enter selects the highlighted choice (usually "Yes"),
    /// Escape cancels — plus explicit `option:N` presets the phone can build
    /// from a numbered menu. M4 refines this once prompt heuristics feed the
    /// dashboard the concrete choices per pane.
    static func bytes(forQuickAction actionId: String) -> String? {
        switch actionId {
        case "approve", "enter", "submit":
            return "\r"
        case "deny", "escape", "cancel":
            return "\u{1b}"
        case "interrupt":
            return "\u{03}"
        default:
            if actionId.hasPrefix("option:") {
                let value = String(actionId.dropFirst("option:".count))
                guard !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
                return value
            }
            return nil
        }
    }
}
