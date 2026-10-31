import Foundation

/// Who holds a pane container's terminal viewport sync suspended.
///
/// Suspension freezes the terminal grid while its container is drawn at a
/// size it should not report to the PTY (a scaled float, PiP or zoomed strip)
/// or is animating towards a new slot. Several of these overlap (a float
/// lifted for a move while it still lifts in place, a docked tile still
/// landing when peek zooms the strip out), so each one suspends under its own
/// owner and resumes only that owner: sync comes back once nobody holds it.
/// A stale completion can then never resume a container another operation
/// still scales.
struct TerminalViewportSuspensionOwner: Hashable, Sendable, CustomStringConvertible {
    let name: String

    init(_ name: String) {
        self.name = name
    }

    var description: String { name }

    /// The strip's own suspension: zoom (drag, peek), animated renders,
    /// divider drags. The legacy `setTerminalViewportSyncSuspended(_:)` API.
    static let strip = Self("strip")
    /// A float drawn larger while it is lifted for a move.
    static let floatLiftScale = Self("float.liftScale")
    /// A float growing from its tile slot to its float frame.
    static let floatLiftInPlace = Self("float.liftInPlace")
    /// A docked float's new tile landing in its slot.
    static let dockSettle = Self("float.dockSettle")
    /// A PiP: the live container drawn scaled down.
    static let pip = Self("pip")
}

/// The owners holding one container's viewport sync suspended.
struct TerminalViewportSuspension: Equatable, Sendable {
    private(set) var owners: Set<TerminalViewportSuspensionOwner> = []

    var isSuspended: Bool {
        !owners.isEmpty
    }

    mutating func acquire(_ owner: TerminalViewportSuspensionOwner) {
        owners.insert(owner)
    }

    /// Drops `owner`; returns whether sync may resume (nobody holds it).
    @discardableResult
    mutating func release(_ owner: TerminalViewportSuspensionOwner) -> Bool {
        owners.remove(owner)
        return owners.isEmpty
    }
}
