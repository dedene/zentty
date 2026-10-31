import Foundation

/// Pane counts that gate commands, shared by the palette/menu availability
/// context and the pane layout menu. Live counts include floats (close,
/// rename, duplicate, next/previous pane); strip counts gate tiled-only
/// commands (focus/move/resize/arrange).
struct PaneAvailabilityCounts: Equatable, Sendable {
    let worklaneCount: Int
    /// Every live pane in the active worklane (tiles + floats).
    let activePaneCount: Int
    /// Strip panes in the active worklane.
    let activeTiledPaneCount: Int
    /// Every live pane across all worklanes.
    let totalPaneCount: Int
    let activeColumnCount: Int
    let focusedColumnPaneCount: Int
    let focusedPaneIsFloat: Bool
    /// `.floating` floats in the active worklane.
    let floatingFloatCount: Int
    /// `.floating` + PiP floats in the active worklane, ignoring `floatsHidden`.
    let shownFloatCount: Int
    /// Tiles + visible `.floating` floats across worklanes (next/previous pane).
    let navigablePaneCount: Int

    init(worklanes: [WorklaneState], activeWorklane: WorklaneState?) {
        let strip = activeWorklane?.paneStripState
        worklaneCount = worklanes.count
        activePaneCount = activeWorklane?.allPanes.count ?? 0
        activeTiledPaneCount = strip?.panes.count ?? 0
        totalPaneCount = worklanes.reduce(0) { $0 + $1.allPanes.count }
        activeColumnCount = strip?.columns.count ?? 0
        focusedColumnPaneCount = strip?.focusedColumn?.panes.count ?? 0
        focusedPaneIsFloat = activeWorklane?.floatOwnsFocus ?? false
        let floats = activeWorklane?.floatingPanes ?? []
        floatingFloatCount = floats.count { $0.mode.isFloating }
        shownFloatCount = floats.count { float in
            if case .minimized = float.mode { return false }
            return true
        }
        navigablePaneCount = worklanes.reduce(0) { count, worklane in
            let unreachableFloats = worklane.floatingPanes.count { float in
                !float.mode.isFloating || worklane.floatsHidden
            }
            return count + worklane.allPanes.count - unreachableFloats
        }
    }

    @MainActor
    init(worklaneStore: WorklaneStore) {
        self.init(worklanes: worklaneStore.worklanes, activeWorklane: worklaneStore.activeWorklane)
    }
}

extension CommandAvailabilityContext {
    init(
        counts: PaneAvailabilityCounts,
        focusedPaneHasRememberedSearch: Bool,
        globalSearchHasRememberedSearch: Bool,
        activeWorklaneHasBranchURL: Bool,
        focusedPaneCanOpenWithPrimary: Bool = false,
        activeWorklaneHasPrimaryServer: Bool = false,
        activeWorklaneHasReviewLookup: Bool = false,
        focusedPaneUnreadToggle: PaneUnreadToggle? = nil,
        focusedPaneAgentFork: AgentForkAvailability? = nil
    ) {
        self.init(
            worklaneCount: counts.worklaneCount,
            activePaneCount: counts.activePaneCount,
            totalPaneCount: counts.totalPaneCount,
            activeColumnCount: counts.activeColumnCount,
            focusedColumnPaneCount: counts.focusedColumnPaneCount,
            focusedPaneHasRememberedSearch: focusedPaneHasRememberedSearch,
            globalSearchHasRememberedSearch: globalSearchHasRememberedSearch,
            activeWorklaneHasBranchURL: activeWorklaneHasBranchURL,
            focusedPaneCanOpenWithPrimary: focusedPaneCanOpenWithPrimary,
            activeWorklaneHasPrimaryServer: activeWorklaneHasPrimaryServer,
            activeWorklaneHasReviewLookup: activeWorklaneHasReviewLookup,
            focusedPaneUnreadToggle: focusedPaneUnreadToggle,
            focusedPaneAgentFork: focusedPaneAgentFork,
            activeTiledPaneCount: counts.activeTiledPaneCount,
            focusedPaneIsFloat: counts.focusedPaneIsFloat,
            floatingFloatCount: counts.floatingFloatCount,
            shownFloatCount: counts.shownFloatCount,
            navigablePaneCount: counts.navigablePaneCount
        )
    }
}
