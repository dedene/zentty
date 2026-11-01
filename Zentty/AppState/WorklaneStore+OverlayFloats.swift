import CoreGraphics
import Foundation

enum TerminalOverlayError: LocalizedError, Equatable {
    case paneNotFound
    case notOpen
    case invalidWorkingDirectory(String)

    var errorDescription: String? {
        switch self {
        case .paneNotFound: "Target pane not found."
        case .notOpen: "This pane has no overlay."
        case .invalidWorkingDirectory(let path): "Overlay directory does not exist: \(path)"
        }
    }
}

/// `zentty overlay open` in store terms.
struct OverlayFloatRequest: Equatable, Sendable {
    /// Shell-wrapped native command; empty runs an interactive shell.
    var command: String
    /// nil inherits the owner's directory.
    var workingDirectory: String?
    /// `--wait`: keep the terminal after the command exits.
    var waitAfterCommand: Bool
    var placement: OverlayPlacement
    /// `--size-percent`, 30–100: share of the inset anchor.
    var sizePercent: Int
    /// `--follow`: select the owner's worklane and focus the overlay.
    var follow: Bool
    /// `--notify`: an overlay opened out of sight is revealed by the first
    /// navigation to its owner (following the notification).
    var notify: Bool

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

struct OverlayFloatOpenResult: Equatable, Sendable {
    let id: PaneID
    /// False when an overlay for the same owner and placement already existed.
    let isNew: Bool
}

/// One row of `zentty overlay list`. The pre-float schema plus `mode`.
struct OverlayFloatEntry: Encodable, Equatable, Sendable {
    let id: String
    /// The owner pane.
    let paneID: String
    let worklaneID: String
    let placement: String
    let exitCode: Int?
    /// `floating`, `pip` or `minimized`.
    let mode: String

    static func json(_ entries: [OverlayFloatEntry]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(entries), as: UTF8.self) + "\n"
    }
}

/// Initial frame of an overlay float, as the pre-float overlay sized itself.
enum OverlayFloatGeometry {
    static let inset: CGFloat = 16

    /// `anchor` inset by 16pt, scaled by `sizePercent` around its centre,
    /// grown to the minimum float size and kept inside `canvas`.
    static func initialFrame(anchor: CGRect, sizePercent: Int, canvas: CGRect) -> CGRect {
        let fraction = CGFloat(min(max(sizePercent, 1), 100)) / 100
        let inset = anchor.insetBy(dx: Self.inset, dy: Self.inset)
        let size = CGSize(
            width: max(inset.width * fraction, FloatLayout.minimumFloatSize.width),
            height: max(inset.height * fraction, FloatLayout.minimumFloatSize.height)
        )
        let frame = CGRect(
            x: inset.midX - size.width / 2,
            y: inset.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        return FloatLayout.clamped(frame, in: canvas)
    }
}

extension WorklaneState {
    /// Owner and placement of an overlay float. An owner-less temporary
    /// float (`zentty float new --temporary`) is not an overlay: overlay
    /// commands never find, list, reuse or re-anchor it.
    func overlayAnchor(of id: PaneID) -> (owner: PaneID?, placement: OverlayPlacement)? {
        guard case .temporary(let owner?, let placement, _) = auxiliaryStateByPaneID[id]?.lifetime else {
            return nil
        }
        return (owner, placement)
    }

    /// The worklane's overlay for `owner` + `placement`: a pane overlay is
    /// per owner, a worklane overlay per worklane.
    func overlayFloatID(owner: PaneID, placement: OverlayPlacement) -> PaneID? {
        FloatingPaneState.bySequence(floatingPanes).first { float in
            guard let anchor = overlayAnchor(of: float.pane.id), anchor.placement == placement else {
                return false
            }
            return placement == .worklane || anchor.owner == owner
        }?.pane.id
    }

    var hasTemporaryFloats: Bool {
        floatingPanes.contains { !isPersistent($0.pane.id) }
    }

    /// Like `hasLivePanes`, but overlay floats don't count: they never keep
    /// a worklane (or window) alive on their own.
    var hasPersistentPanes: Bool {
        hasTiledPanes || floatingPanes.contains { isPersistent($0.pane.id) }
    }

    /// Whether closing `id` leaves no persistent pane: temporary (overlay)
    /// floats never keep a worklane alive and close with it.
    func isLastPersistentPane(_ id: PaneID) -> Bool {
        guard isPersistent(id), containsPane(id: id) else {
            return false
        }
        return !allPanes.contains { $0.id != id && isPersistent($0.id) }
    }

    /// Where a worklane overlay re-anchors when its owner goes: the focused
    /// pane, else the strip focus, else the first persistent pane.
    fileprivate var overlayReanchorCandidate: PaneID? {
        [focusedPaneID, paneStripState.focusedPaneID]
            .compactMap { $0 }
            .first { isPersistent($0) && containsPane(id: $0) }
            ?? allPanes.first { isPersistent($0.id) }?.id
    }
}

/// Compatibility adapter: `zentty overlay open|list|show|close` on
/// temporary floats (floating-panes technical design §8). Overlay ids are
/// pane ids. Owners are kept in `PaneLifetime.temporary`; `reconcileOverlayFloats`
/// closes, moves or re-anchors overlays after every structural change.
extension WorklaneStore {

    // MARK: - Commands

    /// Opens (or returns the existing) overlay float for `ownerID`. Never
    /// blocks: the command starts when the runtime registry next syncs.
    /// `ownerFrame` (canvas coordinates) anchors a pane overlay; nil uses the
    /// owner's float frame, else the canvas.
    @discardableResult
    func openOverlayFloat(
        on ownerID: PaneID,
        request: OverlayFloatRequest,
        canvas: CGRect,
        ownerFrame: CGRect? = nil,
        directoryExists: (String) -> Bool = OverlayFloatRequest.isDirectory
    ) throws -> OverlayFloatOpenResult {
        guard let worklaneIndex = worklaneIndex(containingPane: ownerID) else {
            throw TerminalOverlayError.paneNotFound
        }
        let original = worklanes[worklaneIndex]
        if let existing = original.overlayFloatID(owner: ownerID, placement: request.placement) {
            if request.follow {
                showFloat(existing)
            }
            return OverlayFloatOpenResult(id: existing, isNew: false)
        }
        let directory = request.workingDirectory
            ?? original.auxiliaryStateByPaneID[ownerID]?.shellContext?.path
            ?? original.pane(id: ownerID)?.sessionRequest.workingDirectory
        if let directory, !directoryExists(directory) {
            throw TerminalOverlayError.invalidWorkingDirectory(directory)
        }

        let canvas = canvas.width > 0 && canvas.height > 0 ? canvas : floatCanvasEstimate
        let anchor = request.placement == .pane
            ? ownerFrame ?? original.floatingPane(id: ownerID)?.floatFrame.resolved(in: canvas) ?? canvas
            : canvas
        let frame = OverlayFloatGeometry.initialFrame(anchor: anchor, sizePercent: request.sizePercent, canvas: canvas)

        var worklane = original
        var pane = makePaneWithDirectory(
            in: &worklane,
            existingPaneCount: worklane.paneStripState.columns.count,
            workingDirectory: directory
        )
        pane.sessionRequest.nativeCommand = request.command.isEmpty ? nil : request.command
        pane.sessionRequest.waitAfterNativeCommand = request.waitAfterCommand
        worklane.auxiliaryStateByPaneID[pane.id]?.lifetime = .temporary(
            owner: ownerID,
            placement: request.placement,
            waitAfterCommand: request.waitAfterCommand
        )

        // Out of sight (another worklane, no --follow) it waits as a pill,
        // like the old hidden overlay, until shown or its notification is followed.
        let isActive = worklane.id == activeWorklaneID
        let presented = isActive || request.follow
        worklane.floatingPanes.append(
            FloatingPaneState(
                pane: pane,
                mode: presented ? .floating : .minimized(order: Self.nextMinimizedOrder(in: worklane)),
                floatFrame: NormalizedRect(rect: frame, in: canvas),
                stackOrder: Self.nextStackOrder(in: worklane),
                origin: nil,
                sequence: Self.nextFloatSequence(in: worklane)
            )
        )
        if presented {
            worklane.floatsHidden = false
            worklane.focusedFloatID = pane.id
        } else if request.notify {
            overlayFloatsAwaitingReveal.insert(pane.id)
        }

        if isActive {
            commitFloatChange(from: original, to: worklane)
        } else {
            batchUpdate {
                worklanes[worklaneIndex] = worklane
                notify(.paneStructure(worklane.id))
                notify(.floats(worklane.id))
                if request.follow {
                    selectWorklane(id: worklane.id)
                }
            }
        }
        return OverlayFloatOpenResult(id: pane.id, isNew: true)
    }

    /// The overlay a pane-targeted command acts on: the pane itself when it is
    /// an overlay, else its own pane overlay, else its worklane's overlay.
    func overlayFloatID(targeting paneID: PaneID) -> PaneID? {
        guard let worklaneIndex = worklaneIndex(containingPane: paneID) else {
            return nil
        }
        let worklane = worklanes[worklaneIndex]
        if worklane.overlayAnchor(of: paneID) != nil {
            return paneID
        }
        return worklane.overlayFloatID(owner: paneID, placement: .pane)
            ?? worklane.overlayFloatID(owner: paneID, placement: .worklane)
    }

    /// `zentty overlay list`: every overlay, or (with `paneID`) the pane's own
    /// overlays and its worklane's, sorted by id.
    func overlayFloatEntries(targeting paneID: PaneID?) -> [OverlayFloatEntry] {
        let targetWorklaneID = paneID.flatMap { worklaneIndex(containingPane: $0) }.map { worklanes[$0].id }
        if paneID != nil, targetWorklaneID == nil {
            return []
        }
        var entries: [OverlayFloatEntry] = []
        for worklane in worklanes {
            for float in worklane.floatingPanes {
                let id = float.pane.id
                guard let anchor = worklane.overlayAnchor(of: id) else {
                    continue
                }
                if let paneID {
                    let matches = anchor.placement == .pane
                        ? anchor.owner == paneID || id == paneID
                        : worklane.id == targetWorklaneID
                    guard matches else { continue }
                }
                entries.append(OverlayFloatEntry(
                    id: id.rawValue,
                    paneID: anchor.owner?.rawValue ?? "",
                    worklaneID: worklane.id.rawValue,
                    placement: anchor.placement.rawValue,
                    exitCode: worklane.auxiliaryStateByPaneID[id]?.lastCommandExitCode,
                    mode: float.mode.wireName
                ))
            }
        }
        return entries.sorted { $0.id < $1.id }
    }

    /// `zentty overlay show`: selects the overlay's worklane, restores it if
    /// it was put away, and focuses it.
    func showOverlayFloat(targeting paneID: PaneID) throws {
        guard let id = overlayFloatID(targeting: paneID) else {
            throw TerminalOverlayError.notOpen
        }
        showFloat(id)
    }

    /// `zentty overlay close`.
    func closeOverlayFloat(targeting paneID: PaneID) throws {
        guard let id = overlayFloatID(targeting: paneID) else {
            throw TerminalOverlayError.notOpen
        }
        closeFloatInAnyWorklane(id)
    }

    /// After navigating to `paneID` (following a `--notify` notification):
    /// shows the overlay that was opened out of sight for it, once.
    func revealOverlayFloatAwaitingNavigation(on paneID: PaneID) {
        overlayFloatsAwaitingReveal = overlayFloatsAwaitingReveal.filter { worklaneIndex(containingPane: $0) != nil }
        guard let worklaneIndex = worklaneIndex(containingPane: paneID) else {
            return
        }
        let worklane = worklanes[worklaneIndex]
        let candidates = [paneID]
            + [worklane.overlayFloatID(owner: paneID, placement: .pane),
               worklane.overlayFloatID(owner: paneID, placement: .worklane)].compactMap { $0 }
        guard let id = candidates.first(where: { overlayFloatsAwaitingReveal.contains($0) }) else {
            return
        }
        showFloat(id)
    }

    // MARK: - Close confirmation

    /// Every overlay (temporary float) that closing `paneID` ends, so the
    /// close prompt can ask their terminals: `paneID` itself when it is an
    /// overlay, its pane overlays at any depth (an overlay can own overlays;
    /// reconciliation closes each once its owner is gone), and every overlay
    /// of its worklane when it is the worklane's last persistent pane.
    /// Worklane overlays otherwise re-anchor and survive.
    func temporaryFloatIDs(closingWithPane paneID: PaneID) -> [PaneID] {
        guard let worklaneIndex = worklaneIndex(containingPane: paneID) else {
            return []
        }
        let worklane = worklanes[worklaneIndex]
        let ordered = FloatingPaneState.bySequence(worklane.floatingPanes).map(\.pane.id)
        if worklane.isLastPersistentPane(paneID) {
            return ordered.filter { !worklane.isPersistent($0) }
        }
        var closing: Set<PaneID> = [paneID]
        var grew = true
        while grew {
            grew = false
            for id in ordered where !closing.contains(id) {
                guard let anchor = worklane.overlayAnchor(of: id),
                      anchor.placement == .pane,
                      let owner = anchor.owner,
                      closing.contains(owner) else {
                    continue
                }
                closing.insert(id)
                grew = true
            }
        }
        return ordered.filter { closing.contains($0) && !worklane.isPersistent($0) }
    }

    func temporaryFloatIDs(closingWithWorklane worklaneID: WorklaneID) -> [PaneID] {
        guard let worklane = worklanes.first(where: { $0.id == worklaneID }) else {
            return []
        }
        return FloatingPaneState.bySequence(worklane.floatingPanes)
            .map(\.pane.id)
            .filter { !worklane.isPersistent($0) }
    }

    // MARK: - Owner tracking

    /// Whether `change` can remove or move an overlay's owner.
    static func mayMoveOverlayOwners(_ change: WorklaneChange) -> Bool {
        switch change {
        case .paneStructure, .floats, .worklaneListChanged:
            true
        default:
            false
        }
    }

    /// Keeps overlays with their owners (owner-less temporary floats are left
    /// alone): a pane overlay closes with its owner
    /// and follows it to another worklane; a worklane overlay re-anchors to
    /// the focused pane, and closes once no persistent pane is left. A
    /// worklane left with nothing (its overlays followed their owner out) is
    /// removed. Runs from `notify` before subscribers see the change.
    func reconcileOverlayFloats() {
        guard !isReconcilingOverlayFloats, worklanes.contains(where: \.hasTemporaryFloats) else {
            return
        }
        isReconcilingOverlayFloats = true
        defer { isReconcilingOverlayFloats = false }
        batchUpdate {
            var emptiedWorklaneIDs: Set<WorklaneID> = []
            // An overlay may own another overlay; closing or moving one can
            // orphan the next, so repeat until a pass changes nothing.
            for _ in 0..<4 {
                var leftAny = false
                for worklaneID in worklanes.map(\.id) {
                    guard let snapshot = worklanes.first(where: { $0.id == worklaneID }) else {
                        continue
                    }
                    for float in snapshot.floatingPanes where reconcileOverlayFloat(float.pane.id, in: worklaneID) {
                        emptiedWorklaneIDs.insert(worklaneID)
                        leftAny = true
                    }
                }
                guard leftAny else { break }
            }
            removeEmptyWorklanes(emptiedWorklaneIDs)
        }
    }

    /// Returns true when the overlay left `worklaneID` (closed or moved).
    private func reconcileOverlayFloat(_ id: PaneID, in worklaneID: WorklaneID) -> Bool {
        // A temporary float without an owner (not opened by `zentty overlay`)
        // only ends with its command.
        guard let worklaneIndex = worklanes.firstIndex(where: { $0.id == worklaneID }),
              let anchor = worklanes[worklaneIndex].overlayAnchor(of: id),
              let owner = anchor.owner else {
            return false
        }
        let worklane = worklanes[worklaneIndex]
        switch anchor.placement {
        case .pane:
            guard let ownerIndex = self.worklaneIndex(containingPane: owner) else {
                closeFloatInAnyWorklane(id)
                return true
            }
            guard ownerIndex != worklaneIndex else {
                return false
            }
            moveOverlayFloat(id, from: worklaneIndex, to: ownerIndex)
            return true
        case .worklane:
            if owner != id, worklane.containsPane(id: owner), worklane.isPersistent(owner) {
                return false
            }
            guard let replacement = worklane.overlayReanchorCandidate,
                  case .temporary(_, let placement, let wait)? = worklane.auxiliaryStateByPaneID[id]?.lifetime else {
                closeFloatInAnyWorklane(id)
                return true
            }
            worklanes[worklaneIndex].auxiliaryStateByPaneID[id]?.lifetime = .temporary(
                owner: replacement,
                placement: placement,
                waitAfterCommand: wait
            )
            notify(.floats(worklaneID))
            return false
        }
    }

    /// Closes float `id` in whichever worklane holds it.
    func closeFloatInAnyWorklane(_ id: PaneID) {
        overlayFloatsAwaitingReveal.remove(id)
        guard let worklaneIndex = worklaneIndex(containingPane: id),
              worklanes[worklaneIndex].isFloating(id) else {
            return
        }
        let original = worklanes[worklaneIndex]
        var worklane = original
        detachFloat(id, from: &worklane)
        batchUpdate {
            notify(.paneStructure(worklane.id))
            commitFloat(worklane, from: original, at: worklaneIndex)
        }
    }

    /// Moves a pane overlay after its owner: same frame, in front, keeping a
    /// pill a pill and turning a PiP into a float (the target's corners may be full).
    private func moveOverlayFloat(_ id: PaneID, from sourceIndex: Int, to targetIndex: Int) {
        var source = worklanes[sourceIndex]
        guard let floatIndex = source.floatingPanes.firstIndex(where: { $0.pane.id == id }) else {
            return
        }
        var float = source.floatingPanes.remove(at: floatIndex)
        let auxiliary = source.auxiliaryStateByPaneID.removeValue(forKey: id)
        Self.compactFloatOrders(in: &source)
        if source.focusedFloatID == id {
            moveFocusAway(from: id, in: &source)
        }
        serverRegistry.clear(worklaneID: source.id, paneID: id)

        var target = worklanes[targetIndex]
        float.stackOrder = Self.nextStackOrder(in: target)
        float.sequence = Self.nextFloatSequence(in: target)
        if case .minimized = float.mode {
            float.mode = .minimized(order: Self.nextMinimizedOrder(in: target))
        } else {
            float.mode = .floating
        }
        target.floatingPanes.append(float)
        if let auxiliary {
            target.auxiliaryStateByPaneID[id] = auxiliary
        }

        worklanes[sourceIndex] = source
        worklanes[targetIndex] = target
        for worklaneID in [source.id, target.id] {
            notify(.paneStructure(worklaneID))
            notify(.floats(worklaneID))
        }
    }

    private func removeEmptyWorklanes(_ ids: Set<WorklaneID>) {
        var removedAny = false
        for id in ids {
            guard worklanes.count > 1,
                  let index = worklanes.firstIndex(where: { $0.id == id }),
                  !worklanes[index].hasLivePanes else {
                continue
            }
            worklanes.remove(at: index)
            serverRegistry.clear(worklaneID: id)
            if activeWorklaneID == id {
                activeWorklaneID = worklanes[min(max(index - 1, 0), worklanes.count - 1)].id
            }
            removedAny = true
        }
        if removedAny {
            refreshLastFocusedLocalWorkingDirectory()
            notify(.worklaneListChanged)
        }
    }

    /// Selects the worklane holding float `id`, then restores and focuses it.
    private func showFloat(_ id: PaneID) {
        overlayFloatsAwaitingReveal.remove(id)
        guard let worklaneIndex = worklaneIndex(containingPane: id) else {
            return
        }
        batchUpdate {
            if worklanes[worklaneIndex].id != activeWorklaneID {
                selectWorklane(id: worklanes[worklaneIndex].id)
            }
            focusFloat(id)
        }
    }
}
