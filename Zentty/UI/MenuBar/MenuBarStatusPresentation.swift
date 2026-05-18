import Foundation

struct MenuBarAgentCounts: Equatable, Sendable {
    var running: Int
    var waiting: Int
    var idle: Int

    static let empty = MenuBarAgentCounts(running: 0, waiting: 0, idle: 0)

    var total: Int {
        running + waiting + idle
    }

    var hasActivity: Bool {
        running > 0 || waiting > 0
    }

    mutating func include(_ state: PaneAgentState) {
        switch state {
        case .starting, .running:
            running += 1
        case .needsInput, .unresolvedStop:
            waiting += 1
        case .idle:
            idle += 1
        }
    }
}

struct MenuBarStatusPresentation: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case idle
        case running
        case waiting
    }

    let title: String
    let symbolName: String
    let accessibilityLabel: String
    let tone: Tone

    static func resolve(counts: MenuBarAgentCounts) -> MenuBarStatusPresentation {
        if counts.waiting > 0 {
            return MenuBarStatusPresentation(
                title: "\(counts.running)\u{00B7}\(counts.waiting)",
                symbolName: counts.running > 0 ? "play.circle" : "exclamationmark.circle.fill",
                accessibilityLabel: accessibilityLabel(counts: counts),
                tone: .waiting
            )
        }

        if counts.running > 0 {
            return MenuBarStatusPresentation(
                title: "\(counts.running)",
                symbolName: "play.circle",
                accessibilityLabel: accessibilityLabel(counts: counts),
                tone: .running
            )
        }

        return MenuBarStatusPresentation(
            title: "",
            symbolName: "terminal",
            accessibilityLabel: "No active agent panes",
            tone: .idle
        )
    }

    static func statusLabel(counts: MenuBarAgentCounts) -> String {
        if counts.waiting > 0 {
            return counts.waiting == 1 ? "1 waiting" : "\(counts.waiting) waiting"
        }
        if counts.running > 0 {
            return counts.running == 1 ? "1 running" : "\(counts.running) running"
        }
        if counts.idle > 0 {
            return counts.idle == 1 ? "1 idle" : "\(counts.idle) idle"
        }
        return "No agents"
    }

    static func aggregate(_ counts: [MenuBarAgentCounts]) -> MenuBarAgentCounts {
        counts.reduce(.empty) { partial, next in
            MenuBarAgentCounts(
                running: partial.running + next.running,
                waiting: partial.waiting + next.waiting,
                idle: partial.idle + next.idle
            )
        }
    }

    private static func accessibilityLabel(counts: MenuBarAgentCounts) -> String {
        var parts: [String] = []
        if counts.running > 0 {
            parts.append(counts.running == 1 ? "1 running" : "\(counts.running) running")
        }
        if counts.waiting > 0 {
            parts.append(counts.waiting == 1 ? "1 waiting" : "\(counts.waiting) waiting")
        }
        if counts.idle > 0 {
            parts.append(counts.idle == 1 ? "1 idle" : "\(counts.idle) idle")
        }
        return parts.isEmpty ? "No active agent panes" : "Agent status: \(parts.joined(separator: ", "))"
    }
}

struct MenuBarWorklaneAgentSnapshot: Equatable, Sendable {
    let windowID: WindowID
    let worklaneID: WorklaneID
    let windowTitle: String
    let worklaneTitle: String
    let counts: MenuBarAgentCounts

    var hasAgentPanes: Bool {
        counts.total > 0
    }
}
