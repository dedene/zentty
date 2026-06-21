import Foundation

/// Pure derivation of the server menu's structure from a ranked server context.
///
/// Keeps the visible / manage / hidden split testable without AppKit. The
/// `MainWindowController` builds `NSMenu` items directly from this model.
struct ServerMenuModel: Equatable {
    struct Entry: Equatable {
        let server: DetectedServer
        let port: Int?
        let isPrimary: Bool
    }

    /// Visible servers as direct open items, ordered for display.
    let visible: [Entry]
    /// Visible, non-manual servers with a known port — offered "Ignore port N",
    /// and "Stop server" for those backed by a process we own (see `isStoppable`).
    let manageable: [Entry]
    /// Servers suppressed by an ignored-port rule — offered "Stop ignoring port N".
    let hidden: [Entry]

    var isEmpty: Bool {
        visible.isEmpty && hidden.isEmpty
    }

    init(context: WorklaneServerContext) {
        let primaryID = context.primaryServer?.id

        visible = ServerMenuOrdering.sortedForDisplay(context.servers).map { server in
            Entry(server: server, port: Self.port(of: server), isPrimary: server.id == primaryID)
        }
        manageable = visible.filter { $0.server.source != .manual && $0.port != nil }

        let hiddenServers = context.ranked.filter { $0.tier == .hidden }.map(\.server)
        hidden = ServerMenuOrdering.sortedForDisplay(hiddenServers).map { server in
            Entry(server: server, port: Self.port(of: server), isPrimary: false)
        }
    }

    static func port(of server: DetectedServer) -> Int? {
        server.url.port ?? server.ports.first
    }

    /// Whether the process behind `server` is one we can prove we own and may
    /// therefore stop. Only scanner-detected servers attributed by shell-PID
    /// ancestry (`.pid` confidence) qualify; Docker and cwd/worklane-attributed
    /// servers point at processes we don't necessarily control.
    static func isStoppable(_ server: DetectedServer) -> Bool {
        server.source == .scanner && server.confidence == .pid
    }
}
