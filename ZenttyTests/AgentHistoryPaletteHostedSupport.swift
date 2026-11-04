import AppKit
import Carbon.HIToolbox
@testable import Zentty

// Support for `AgentHistoryPaletteHostedTests`: a terminal that records the keys it receives,
// session fixtures and event builders. The palette's service fakes come from
// `ZenttyLogicTests/Support/AgentHistoryFakes.swift` (compiled into both test targets).

/// Every keyDown that reached any terminal surface in the window.
@MainActor
final class TerminalKeyRecorder {
    private(set) var keyCodes: [UInt16] = []
    private(set) var views: [KeyRecordingTerminalView] = []

    func record(_ event: NSEvent) {
        keyCodes.append(event.keyCode)
    }

    func register(_ view: KeyRecordingTerminalView) {
        views.append(view)
    }
}

/// A terminal surface that takes first responder and records keys instead of typing them.
@MainActor
final class KeyRecordingTerminalView: NSView, TerminalFocusReporting, TerminalScrollRouting, TerminalContextMenuConfiguring {
    weak var recorder: TerminalKeyRecorder?
    var onFocusDidChange: ((Bool) -> Void)?
    var onScrollWheel: ((NSEvent) -> Bool)?
    var contextMenuBuilder: ((NSEvent, NSMenu?) -> NSMenu?)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        onFocusDidChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusDidChange?(false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        recorder?.record(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self {
            recorder?.record(event)
        }
        return false
    }
}

/// Starts no process; reports the requested folder as the working directory, like the mock.
@MainActor
final class KeyRecordingTerminalAdapter: TerminalAdapter {
    private let surfaceView: KeyRecordingTerminalView
    private var metadata = TerminalMetadata()

    var hasScrollback: Bool { false }
    var cellWidth: CGFloat { 0 }
    var cellHeight: CGFloat { 0 }
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?

    init(recorder: TerminalKeyRecorder) {
        surfaceView = KeyRecordingTerminalView(frame: .zero)
        surfaceView.recorder = recorder
        recorder.register(surfaceView)
    }

    func makeTerminalView() -> NSView { surfaceView }

    func startSession(using request: TerminalSessionRequest) throws {
        metadata.title = "shell"
        metadata.currentWorkingDirectory = request.workingDirectory
        metadataDidChange?(metadata)
    }

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}
    func sendText(_ text: String) {}
    func close() {}
}

enum AgentHistoryHostedFixtures {
    static let root = "/tmp/agent-history-hosted-tests"

    static func session(_ id: Int64, title: String, minutesAgo: Int64) -> AgentHistorySessionSummary {
        let updated = 1_800_000_000_000 - minutesAgo * 60_000
        return AgentHistorySessionSummary(
            id: id, sourceID: 1, sourceRoot: "\(root)/.claude", agent: .claude,
            nativeID: String(format: "7f3c9a2e-41d0-4b6a-9c11-%012lld", id), title: title, titleKind: .generated,
            cwd: "\(root)/zentty", branch: "main", model: "opus",
            createdAtMs: updated - 600_000, updatedAtMs: updated, turnCount: 3
        )
    }

    static var readyStatus: AgentHistoryStatus {
        var status = AgentHistoryStatus.off
        status.isStateLoaded = true
        status.isEnabled = true
        status.hasConsented = true
        status.enabledAgents = Set(AgentHistoryAgent.allCases)
        status.state = .watching
        status.indexedSessions = 3
        status.indexExists = true
        status.tokenizer = .trigram
        status.isBackfillComplete = true
        status.revision = 1
        return status
    }

    static var claudeDetected: AgentHistoryDetectedSource {
        AgentHistoryDetectedSource(
            agent: .claude, rootPath: "\(root)/.claude", isFound: true,
            sessionCount: 3, checkedPaths: ["\(root)/.claude"], problem: nil
        )
    }

    static var retention: ClaudeRetentionStatus {
        ClaudeRetentionStatus(
            configDirectory: URL(fileURLWithPath: "\(root)/.claude"),
            settingsFileURL: URL(fileURLWithPath: "\(root)/.claude/settings.json"),
            effectiveDays: 365, source: .userSettings, readError: nil
        )
    }
}

enum HostedKey {
    case up, down, `return`, commandReturn, escape, commandY, shortcut

    var keyCode: UInt16 {
        switch self {
        case .up: UInt16(kVK_UpArrow)
        case .down: UInt16(kVK_DownArrow)
        case .return, .commandReturn: UInt16(kVK_Return)
        case .escape: UInt16(kVK_Escape)
        case .commandY: UInt16(kVK_ANSI_Y)
        case .shortcut: UInt16(kVK_ANSI_H)
        }
    }

    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .up, .down: [.numericPad, .function]
        case .return, .escape: []
        case .commandReturn, .commandY: [.command]
        case .shortcut: [.command, .shift]
        }
    }

    var characters: String {
        switch self {
        case .up: String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
        case .down: String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        case .return, .commandReturn: "\r"
        case .escape: "\u{1b}"
        case .commandY: "y"
        case .shortcut: "h"
        }
    }

    @MainActor
    func event(in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: self == .shortcut ? "H" : characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}

extension NSView {
    func agentHistoryDescendant<T: NSView>(ofType type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T {
                return match
            }
            if let match = subview.agentHistoryDescendant(ofType: type) {
                return match
            }
        }
        return nil
    }

    func agentHistoryDescendants<T: NSView>(ofType type: T.Type) -> [T] {
        subviews.flatMap { subview -> [T] in
            var matches = subview.agentHistoryDescendants(ofType: type)
            if let match = subview as? T {
                matches.insert(match, at: 0)
            }
            return matches
        }
    }
}
