import CoreGraphics
import Foundation

/// `zentty pane float|dock|pip|minimize|restore` and `zentty float
/// new|list|hide|show`: the CLI's target-state semantics on top of the float
/// operations. Each acts on whichever worklane holds the pane, on screen or not.
extension WorklaneStore {

    /// Moves `paneID` to the state `action` names. Already there is a no-op;
    /// a tile is floated first when the action needs a float (`tileFrame`, in
    /// `canvas` coordinates, remembers where it came from). `corner` only
    /// matters for `.pip` (nil keeps the PiP's corner, else bottom-right).
    /// Throws for an unknown pane and for `.restore` on a tile.
    func applyFloatAction(
        _ action: PaneFloatAction,
        to paneID: PaneID,
        corner: FloatCorner? = nil,
        canvas: CGRect,
        tileFrame: CGRect? = nil
    ) throws {
        guard let worklaneIndex = worklaneIndex(containingPane: paneID) else {
            throw PaneRoutingError.paneNotFound
        }
        let canvas = canvas.width > 0 && canvas.height > 0 ? canvas : floatCanvasEstimate
        let mode = worklanes[worklaneIndex].floatingPane(id: paneID)?.mode
        if action == .restore, mode == nil {
            throw FloatControlIPCError.notFloating(paneID.rawValue)
        }
        try Self.refuseFloatingSoleTile(action, paneID: paneID, in: worklanes[worklaneIndex])
        batchUpdate {
            switch action {
            case .float:
                switch mode {
                case nil:
                    floatPane(paneID, canvas: canvas, tileFrame: tileFrame)
                case .floating?:
                    break
                case .pip?, .minimized?:
                    restoreFloat(paneID)
                }
            case .dock:
                if mode != nil {
                    dockPane(paneID, target: .origin)
                }
            case .pip:
                if mode == nil {
                    floatPane(paneID, canvas: canvas, tileFrame: tileFrame)
                }
                pipPane(paneID, corner: corner)
            case .minimize:
                if mode == nil {
                    floatPane(paneID, canvas: canvas, tileFrame: tileFrame)
                }
                minimizePane(paneID)
            case .restore:
                restoreFloat(paneID)
            }
        }
    }

    /// Throws when `action` would float the worklane's only tile (`float`,
    /// `pip` and `minimize` lift a tile first; `dock` and `restore` never do).
    static func refuseFloatingSoleTile(_ action: PaneFloatAction, paneID: PaneID, in worklane: WorklaneState) throws {
        switch action {
        case .float, .pip, .minimize:
            if worklane.isSoleTile(paneID) {
                throw FloatControlIPCError.soleTile(paneID.rawValue)
            }
        case .dock, .restore:
            break
        }
    }

    /// `zentty float new`: a focused float in `sourcePaneID`'s worklane,
    /// centred at the default size. It starts in `workingDirectory`, else in
    /// the source pane's directory and shell context (like ⌥⌘N; its launch
    /// directory when the shell has not reported one yet), and types
    /// `command` into its shell. A temporary float is never restored and
    /// does not keep its worklane open; it is not an overlay (no owner).
    @discardableResult
    func newFloat(
        from sourcePaneID: PaneID,
        workingDirectory: String?,
        command: String?,
        temporary: Bool,
        canvas: CGRect,
        directoryExists: (String) -> Bool = OverlayFloatRequest.isDirectory
    ) throws -> PaneID {
        guard let worklaneIndex = worklaneIndex(containingPane: sourcePaneID) else {
            throw PaneRoutingError.paneNotFound
        }
        if let workingDirectory, !directoryExists(workingDirectory) {
            throw FloatControlIPCError.invalidWorkingDirectory(workingDirectory)
        }
        let original = worklanes[worklaneIndex]
        var worklane = original
        let source = duplicateSourceInfo(for: sourcePaneID, in: worklane)
        let canvas = canvas.width > 0 && canvas.height > 0 ? canvas : floatCanvasEstimate
        let pane = makePaneWithDirectory(
            in: &worklane,
            existingPaneCount: worklane.paneStripState.columns.count,
            workingDirectory: workingDirectory
                ?? source?.workingDirectory
                ?? original.pane(id: sourcePaneID)?.sessionRequest.workingDirectory,
            sourceShellContext: workingDirectory == nil ? source?.shellContext : nil,
            command: command
        )
        if temporary {
            worklane.auxiliaryStateByPaneID[pane.id]?.lifetime = .temporary(
                owner: nil,
                placement: .worklane,
                waitAfterCommand: false
            )
        }
        let frame = FloatLayout.centeredFrame(size: FloatLayout.defaultFloatSize(canvas: canvas), canvas: canvas)
        worklane.floatingPanes.append(
            FloatingPaneState(
                pane: pane,
                mode: .floating,
                floatFrame: NormalizedRect(rect: frame, in: canvas),
                stackOrder: Self.nextStackOrder(in: worklane),
                origin: nil,
                sequence: Self.nextFloatSequence(in: worklane)
            )
        )
        worklane.floatsHidden = false
        worklane.focusedFloatID = pane.id
        commitFloat(worklane, from: original, at: worklaneIndex)
        return pane.id
    }

    /// `zentty float list`: the worklane's floats in `pane list` order (and
    /// numbering), with where each sits and what it is doing.
    func floatListEntries(in worklaneID: WorklaneID, windowID: WindowID?) -> [FloatListEntry] {
        guard let worklane = worklanes.first(where: { $0.id == worklaneID }) else {
            return []
        }
        let indexByPaneID = Dictionary(
            uniqueKeysWithValues: worklane.allPanes.enumerated().map { ($1.id, $0 + 1) }
        )
        let focusedPaneID = worklane.focusedPaneID
        return FloatingPaneState.bySequence(worklane.floatingPanes).map { float in
            let id = float.pane.id
            let auxiliaryState = worklane.auxiliaryStateByPaneID[id]
            var frame: FloatListEntry.Frame?
            var corner: String?
            switch float.mode {
            case .floating:
                frame = Self.topLeftFrame(float.floatFrame)
            case .pip(let pipCorner, _):
                corner = pipCorner.wireName
            case .minimized:
                break
            }
            return FloatListEntry(
                id: id.rawValue,
                index: indexByPaneID[id] ?? 0,
                worklaneID: worklane.id.rawValue,
                windowID: windowID?.rawValue,
                title: WorklaneContextFormatter.trimmed(float.pane.customTitle) ?? float.pane.title,
                workingDirectory: auxiliaryState?.shellContext?.path,
                mode: float.mode.wireName,
                frame: frame,
                corner: corner,
                status: Self.floatListStatus(auxiliaryState),
                agentTool: auxiliaryState?.agentStatus?.tool.displayName,
                isFocused: focusedPaneID == id,
                isHidden: worklane.floatsHidden && !Self.isMinimized(float.mode),
                isTemporary: !worklane.isPersistent(id)
            )
        }
    }

    // MARK: - List helpers

    /// The stored y-up fractions as y-down fractions, rounded to 4 places so
    /// the JSON stays readable.
    static func topLeftFrame(_ rect: NormalizedRect) -> FloatListEntry.Frame {
        func rounded(_ value: Double) -> Double {
            (value * 10_000).rounded() / 10_000
        }
        return FloatListEntry.Frame(
            x: rounded(rect.x),
            y: rounded(1 - rect.y - rect.height),
            width: rounded(rect.width),
            height: rounded(rect.height)
        )
    }

    /// The pill/PiP status (UX spec §17) as a wire token; a running shell
    /// command without an agent is `running`.
    static func floatListStatus(_ auxiliaryState: PaneAuxiliaryState?) -> String {
        let attention = auxiliaryState.flatMap {
            WorklaneAttentionSummaryBuilder.attentionState(for: $0.presentation)
        }
        switch attention {
        case .running: return "working"
        case .needsInput: return "needs-input"
        case .ready: return "done"
        case .unresolvedStop: return "stopped"
        case .checkBack: return "check-back"
        case nil:
            return auxiliaryState?.shellActivityState == .commandRunning ? "running" : "idle"
        }
    }

    private static func isMinimized(_ mode: FloatingPaneMode) -> Bool {
        if case .minimized = mode { return true }
        return false
    }
}

extension FloatCorner {
    /// CLI spelling (`FloatControlIPC.cornerNames`).
    var wireName: String {
        switch self {
        case .topLeft: "top-left"
        case .topRight: "top-right"
        case .bottomLeft: "bottom-left"
        case .bottomRight: "bottom-right"
        }
    }

    init?(wireName: String) {
        guard let corner = Self.allCases.first(where: { $0.wireName == wireName }) else {
            return nil
        }
        self = corner
    }
}
