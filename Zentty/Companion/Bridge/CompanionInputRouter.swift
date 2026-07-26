import Foundation
import OSLog

private let companionInputLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CompanionInput")

// MARK: - Input sink seam

/// The injection primitives the router needs. Implemented by `AppDelegate`
/// (resolve pane → terminal runtime); faked in tests. Both return `false` when
/// the pane is unknown or has no live runtime.
///
/// Two paths, deliberately: printable text goes through `companionSendText`
/// (libghostty's text/paste path), while non-printable keys go through
/// `companionSendKey` (a real key event). The split matters — the text path wraps
/// input in bracketed paste, which strips the `ESC` from cursor-key CSI sequences
/// and turns a submitting `CR` into a literal `LF`. Control keys must not take it.
@MainActor
protocol CompanionInputSink: AnyObject {
    func companionSendText(_ text: String, toPaneId paneId: String) -> Bool
    func companionSendKey(_ key: TerminalSpecialKey, toPaneId paneId: String) -> Bool
}

// MARK: - Audit trail

/// One phone-originated injection attempt, as recorded for the audit trail.
///
/// Deliberately content-free: a paired phone types passwords, tokens and API
/// keys into panes, so the record carries the input *family* and a character
/// count and nothing else. Do not add the injected text, the resolved key, or
/// the quick-action id to this struct — the audit trail must stay safe to read
/// out of the unified log by anyone who can read the log.
struct CompanionInputAuditRecord: Equatable {
    /// Which input family the message belonged to.
    enum Kind: String, Equatable {
        case text
        case key
        case quickAction
    }

    /// What the injection attempt did.
    enum Outcome: String, Equatable {
        case ok
        case paneNotFound = "pane_not_found"
        case unavailable
        case unknownAction = "unknown_action"
    }

    /// Pane the input was aimed at (as named on the wire).
    let paneId: String
    /// The session's *authenticated* device, never the payload's advisory id.
    /// `nil` when the connection has no established identity.
    let deviceId: String?
    let kind: Kind
    /// Character count of the injected text; `0` for key events.
    let length: Int
    let outcome: Outcome
}

/// Sink for the audit trail, behind a protocol so tests can assert on what is
/// recorded. Production writes to the unified log.
@MainActor
protocol CompanionInputAuditing: AnyObject {
    func record(_ record: CompanionInputAuditRecord)
}

/// Default audit sink.
///
/// Zentty has no persisted event store to append to — `AgentEventBridge` is a
/// CLI-side hook parser that posts transient status payloads over IPC, and
/// `AgentStatusCenter` keeps only current state — so injections go to the
/// unified log at `notice`, which is persisted to disk and survives a crash.
@MainActor
final class CompanionInputOSLogAudit: CompanionInputAuditing {
    func record(_ record: CompanionInputAuditRecord) {
        companionInputLogger.notice(
            """
            companion input pane=\(record.paneId, privacy: .public) \
            device=\(record.deviceId ?? "unpaired", privacy: .public) \
            kind=\(record.kind.rawValue, privacy: .public) \
            length=\(record.length, privacy: .public) \
            outcome=\(record.outcome.rawValue, privacy: .public)
            """
        )
    }
}

// MARK: - Router

/// Turns `input.text` / `input.key` / `input.quickAction` messages into terminal
/// byte injections on the resolved pane, and produces the correlated
/// `input.ack`. `@MainActor` because injection touches the runtime graph.
///
/// Also the single chokepoint for the audit trail: every phone-originated
/// injection attempt, successful or not, is recorded here.
@MainActor
final class CompanionInputRouter {
    private weak var sink: CompanionInputSink?
    private let audit: CompanionInputAuditing

    init(sink: CompanionInputSink, audit: CompanionInputAuditing = CompanionInputOSLogAudit()) {
        self.sink = sink
        self.audit = audit
    }

    /// Handles an input-family message. Returns the ack payload the session
    /// sends back (correlated to the request via the envelope `replyTo`), or
    /// `nil` for a message this router does not own.
    ///
    /// `deviceId` must be the connection's *authenticated* device (the session's
    /// `pairedDeviceId`); the payloads carry no trustworthy identity of their own.
    func handle(_ message: CompanionMessage, fromDeviceId deviceId: String?) -> CompanionInputAck? {
        switch message {
        case .inputText(let payload):
            return injectText(payload.text, into: payload.paneId, kind: .text, deviceId: deviceId)
        case .inputKey(let payload):
            return injectKey(
                Self.specialKey(for: payload.key),
                into: payload.paneId,
                kind: .key,
                deviceId: deviceId
            )
        case .inputQuickAction(let payload):
            switch Self.action(forQuickAction: payload.actionId) {
            case .key(let key):
                return injectKey(key, into: payload.paneId, kind: .quickAction, deviceId: deviceId)
            case .text(let text):
                return injectText(text, into: payload.paneId, kind: .quickAction, deviceId: deviceId)
            case .none:
                return finish(
                    outcome: .unknownAction,
                    paneId: payload.paneId,
                    deviceId: deviceId,
                    kind: .quickAction,
                    length: 0
                )
            }
        default:
            return nil
        }
    }

    private func injectText(
        _ text: String,
        into paneId: String,
        kind: CompanionInputAuditRecord.Kind,
        deviceId: String?
    ) -> CompanionInputAck {
        guard let sink else {
            return finish(outcome: .unavailable, paneId: paneId, deviceId: deviceId, kind: kind, length: text.count)
        }
        let ok = sink.companionSendText(text, toPaneId: paneId)
        return finish(
            outcome: ok ? .ok : .paneNotFound,
            paneId: paneId,
            deviceId: deviceId,
            kind: kind,
            length: text.count
        )
    }

    private func injectKey(
        _ key: TerminalSpecialKey,
        into paneId: String,
        kind: CompanionInputAuditRecord.Kind,
        deviceId: String?
    ) -> CompanionInputAck {
        guard let sink else {
            return finish(outcome: .unavailable, paneId: paneId, deviceId: deviceId, kind: kind, length: 0)
        }
        let ok = sink.companionSendKey(key, toPaneId: paneId)
        return finish(outcome: ok ? .ok : .paneNotFound, paneId: paneId, deviceId: deviceId, kind: kind, length: 0)
    }

    /// Records the attempt and turns the outcome into the wire ack. Every exit
    /// from an input message goes through here, so nothing injects unrecorded.
    private func finish(
        outcome: CompanionInputAuditRecord.Outcome,
        paneId: String,
        deviceId: String?,
        kind: CompanionInputAuditRecord.Kind,
        length: Int
    ) -> CompanionInputAck {
        audit.record(
            CompanionInputAuditRecord(
                paneId: paneId,
                deviceId: deviceId,
                kind: kind,
                length: length,
                outcome: outcome
            )
        )
        return CompanionInputAck(ok: outcome == .ok, error: outcome == .ok ? nil : outcome.rawValue)
    }

    // MARK: Key mapping

    /// Named wire key → the terminal's `TerminalSpecialKey`. The surface encodes
    /// the actual bytes via a real key event, so arrows honor the pane's DECCKM
    /// (application-cursor-key) mode and Return submits — neither of which survives
    /// the paste/text path. This 1:1 map is the whole "key policy": every named key
    /// is a key event, never pasted text.
    static func specialKey(for key: CompanionInputKey) -> TerminalSpecialKey {
        switch key {
        case .enter: return .enter
        case .escape: return .escape
        case .tab: return .tab
        case .up: return .up
        case .down: return .down
        case .right: return .right
        case .left: return .left
        case .ctrlC: return .ctrlC
        case .ctrlD: return .ctrlD
        case .ctrlZ: return .ctrlZ
        case .ctrlR: return .ctrlR
        }
    }

    /// How a quick action is delivered: a real key event, pasted text, or nothing.
    enum QuickAction: Equatable {
        case key(TerminalSpecialKey)
        case text(String)
        case none
    }

    /// Quick-action id → delivery.
    ///
    /// v1 is deliberately coarse: without the pane's current prompt shape the
    /// bridge cannot know which numbered option "approve" maps to, so it sends
    /// the safe defaults — Enter selects the highlighted choice (usually "Yes"),
    /// Escape cancels — plus explicit `option:N` presets the phone can build
    /// from a numbered menu. Enter/Escape/interrupt go through the key path (so
    /// Enter actually submits); `option:N` is a printable digit, so it pastes as
    /// text. M4 refines this once prompt heuristics feed the dashboard the
    /// concrete choices per pane.
    static func action(forQuickAction actionId: String) -> QuickAction {
        switch actionId {
        case "approve", "enter", "submit":
            return .key(.enter)
        case "deny", "escape", "cancel":
            return .key(.escape)
        case "interrupt":
            return .key(.ctrlC)
        default:
            if actionId.hasPrefix("option:") {
                let value = String(actionId.dropFirst("option:".count))
                guard !value.isEmpty, value.allSatisfy(\.isNumber) else { return .none }
                return .text(value)
            }
            return .none
        }
    }
}
