/// Which minimized float's live terminal the pill peek holds, and what has
/// to happen when the hover changes. Pure: `PillPeekView` runs the steps.
///
/// The peek borrows the pane's container from the float layer on hover
/// (`lend`), shows it while the pill stays hovered, fades out on hover-out
/// still holding it, and hands it back (`giveBack`) once the fade is done.
/// Hovering the same pill again mid-fade keeps the loan; any other pane, or
/// the pane leaving the pill bar (restored, popped, closed, another worklane),
/// hands it back at once so the float layer can mount it.
struct PillPeekLease: Equatable {
    enum Phase: Equatable {
        case idle
        /// Shown and live (the runtime is un-occluded).
        case showing(PaneID)
        /// Fading out, still holding the container (occluded again).
        case leaving(PaneID)
    }

    enum Step: Equatable {
        /// Borrow the pane's container and host it scaled.
        case lend(PaneID)
        /// Hand the container back now.
        case giveBack(PaneID)
        /// Fade in (also cancels a fade-out in progress).
        case fadeIn
        case fadeOut
    }

    private(set) var phase: Phase = .idle

    /// The pane the peek draws live; nil while idle or fading out.
    var visiblePaneID: PaneID? {
        if case .showing(let paneID) = phase { return paneID }
        return nil
    }

    /// The pane whose container the peek holds (showing or fading out).
    var heldPaneID: PaneID? {
        switch phase {
        case .idle: nil
        case .showing(let paneID), .leaving(let paneID): paneID
        }
    }

    /// The pointer moved onto `paneID`'s pill, or off every pill (nil).
    mutating func hover(_ paneID: PaneID?) -> [Step] {
        guard let paneID else {
            guard case .showing(let held) = phase else { return [] }
            phase = .leaving(held)
            return [.fadeOut]
        }
        switch phase {
        case .idle:
            phase = .showing(paneID)
            return [.lend(paneID), .fadeIn]
        case .showing(let held) where held == paneID:
            return []
        case .leaving(let held) where held == paneID:
            phase = .showing(paneID)
            return [.fadeIn]
        case .showing(let held), .leaving(let held):
            phase = .showing(paneID)
            return [.giveBack(held), .lend(paneID), .fadeIn]
        }
    }

    /// The fade-out that started on hover-out finished.
    mutating func fadeOutFinished(_ paneID: PaneID) -> [Step] {
        guard phase == .leaving(paneID) else { return [] }
        phase = .idle
        return [.giveBack(paneID)]
    }

    /// The held pane is no longer one of `pillIDs`: hand it back now.
    mutating func release(keeping pillIDs: Set<PaneID>) -> [Step] {
        guard let held = heldPaneID, !pillIDs.contains(held) else { return [] }
        phase = .idle
        return [.giveBack(held)]
    }

    /// The float layer had nothing to lend for `paneID`.
    mutating func lendFailed(_ paneID: PaneID) {
        guard phase == .showing(paneID) else { return }
        phase = .idle
    }
}
