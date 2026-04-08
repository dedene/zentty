import Foundation

@MainActor
struct GlobalSearchState: Equatable {
    var needle: String
    var selected: Int
    var total: Int
    var hasRememberedSearch: Bool
    var isHUDVisible: Bool

    init(
        needle: String = "",
        selected: Int = -1,
        total: Int = 0,
        hasRememberedSearch: Bool = false,
        isHUDVisible: Bool = false
    ) {
        self.needle = needle
        self.selected = selected
        self.total = total
        self.hasRememberedSearch = hasRememberedSearch
        self.isHUDVisible = isHUDVisible
    }
}

@MainActor
struct GlobalSearchTarget: Equatable, Hashable {
    let worklaneID: WorklaneID
    let paneID: PaneID
}

@MainActor
final class GlobalSearchCoordinator {
    private enum Direction {
        case next
        case previous
    }

    private struct PaneResultState {
        var total: Int = 0
        var selected: Int = -1
    }

    private struct Selection: Equatable {
        let paneID: PaneID
        let index: Int
    }

    private let orderedTargetsProvider: () -> [GlobalSearchTarget]
    private let runtimeProvider: (PaneID) -> PaneRuntime?
    private let navigateToTarget: (WorklaneID, PaneID, @escaping @MainActor () -> Void) -> Void
    private let endAllLocalSearches: () -> Void
    private var queryUpdateWorkItem: DispatchWorkItem?
    private var frozenTargets: [GlobalSearchTarget] = []
    private var paneResults: [PaneID: PaneResultState] = [:]
    private var pendingPaneIDsAwaitingTotals: Set<PaneID> = []
    private var currentSelection: Selection?
    private var pendingNavigationDirection: Direction?

    var onStateDidChange: ((GlobalSearchState) -> Void)?

    private(set) var state = GlobalSearchState() {
        didSet {
            guard state != oldValue else {
                return
            }

            onStateDidChange?(state)
        }
    }

    init(
        orderedTargetsProvider: @escaping () -> [GlobalSearchTarget],
        runtimeProvider: @escaping (PaneID) -> PaneRuntime?,
        navigateToTarget: @escaping (WorklaneID, PaneID, @escaping @MainActor () -> Void) -> Void,
        endAllLocalSearches: @escaping () -> Void
    ) {
        self.orderedTargetsProvider = orderedTargetsProvider
        self.runtimeProvider = runtimeProvider
        self.navigateToTarget = navigateToTarget
        self.endAllLocalSearches = endAllLocalSearches
    }

    func show() {
        if !state.hasRememberedSearch, state.needle.isEmpty {
            endAllLocalSearches()
            captureFrozenTargets()
            clearPaneResults()
        }

        state.isHUDVisible = true
    }

    func hide() {
        end()
    }

    func end() {
        queryUpdateWorkItem?.cancel()
        queryUpdateWorkItem = nil

        for target in frozenTargets {
            runtimeProvider(target.paneID)?.endGlobalSearch()
        }

        frozenTargets = []
        paneResults = [:]
        pendingPaneIDsAwaitingTotals = []
        currentSelection = nil
        pendingNavigationDirection = nil
        state = .init()
    }

    func updateQuery(_ needle: String) {
        if state.hasRememberedSearch == false, state.isHUDVisible == false {
            show()
        }

        queryUpdateWorkItem?.cancel()
        captureFrozenTargets()
        clearPaneResults()
        pendingNavigationDirection = nil

        state.needle = needle
        state.selected = -1
        state.total = 0
        state.isHUDVisible = true
        if needle.isEmpty {
            state.hasRememberedSearch = false
            pendingPaneIDsAwaitingTotals = []
            for target in frozenTargets {
                runtimeProvider(target.paneID)?.endGlobalSearch()
            }
            return
        }

        state.hasRememberedSearch = true

        let dispatchUpdate: () -> Void = { [weak self] in
            self?.dispatchQueryUpdate(needle)
        }

        if needle.count >= 3 {
            dispatchUpdate()
            return
        }

        let workItem = DispatchWorkItem(block: dispatchUpdate)
        queryUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    func findNext() {
        navigate(.next)
    }

    func findPrevious() {
        navigate(.previous)
    }

    func handleSearchEvent(for paneID: PaneID, event: TerminalSearchEvent) {
        guard paneResults[paneID] != nil else {
            return
        }

        switch event {
        case .started:
            return
        case .ended:
            paneResults[paneID] = PaneResultState()
            pendingPaneIDsAwaitingTotals.remove(paneID)
            if currentSelection?.paneID == paneID {
                currentSelection = nil
                state.selected = -1
            }
            recomputeTotal()
        case .total(let total):
            paneResults[paneID, default: PaneResultState()].total = total
            pendingPaneIDsAwaitingTotals.remove(paneID)
            if let currentSelection, currentSelection.paneID == paneID, currentSelection.index >= total {
                self.currentSelection = nil
                paneResults[paneID]?.selected = -1
                state.selected = -1
            }
            recomputeTotal()
            performPendingNavigationIfReady()
        case .selected(let selected):
            if selected < 0 {
                paneResults[paneID]?.selected = -1
                if currentSelection?.paneID == paneID {
                    currentSelection = nil
                    state.selected = -1
                }
                return
            }

            for targetPaneID in paneResults.keys {
                paneResults[targetPaneID]?.selected = targetPaneID == paneID ? selected : -1
            }
            currentSelection = Selection(paneID: paneID, index: selected)
            state.selected = globalOrdinal(for: paneID, selectedIndex: selected)
        }
    }

    func reconcileTargets(with worklanes: [WorklaneState]) {
        guard state.hasRememberedSearch else {
            return
        }

        let livePaneIDs = Set(worklanes.flatMap { worklane in
            worklane.paneStripState.panes.map(\.id)
        })

        frozenTargets.removeAll { !livePaneIDs.contains($0.paneID) }
        paneResults = paneResults.filter { livePaneIDs.contains($0.key) }

        if let currentSelection, !livePaneIDs.contains(currentSelection.paneID) {
            self.currentSelection = nil
            state.selected = -1
        }

        recomputeTotal()
        if let currentSelection {
            state.selected = globalOrdinal(for: currentSelection.paneID, selectedIndex: currentSelection.index)
        }
    }

    private func navigate(_ direction: Direction) {
        guard state.hasRememberedSearch else {
            return
        }

        state.isHUDVisible = true
        flushPendingQueryUpdateIfNeeded()

        guard state.total > 0 else {
            if !pendingPaneIDsAwaitingTotals.isEmpty {
                pendingNavigationDirection = direction
            }
            return
        }
        pendingNavigationDirection = nil

        let liveTargets = frozenTargets.filter { runtimeProvider($0.paneID) != nil }
        guard !liveTargets.isEmpty else {
            return
        }

        guard let currentSelection else {
            navigateFromUnselected(direction: direction, liveTargets: liveTargets)
            return
        }

        guard let currentTargetIndex = liveTargets.firstIndex(where: { $0.paneID == currentSelection.paneID }),
              let currentPaneState = paneResults[currentSelection.paneID] else {
            self.currentSelection = nil
            state.selected = -1
            navigateFromUnselected(direction: direction, liveTargets: liveTargets)
            return
        }

        switch direction {
        case .next:
            if currentSelection.index + 1 < currentPaneState.total {
                setSelection(paneID: currentSelection.paneID, selectedIndex: currentSelection.index + 1)
                runtimeProvider(currentSelection.paneID)?.findNextInGlobalSearch()
                return
            }
        case .previous:
            if currentSelection.index > 0 {
                setSelection(paneID: currentSelection.paneID, selectedIndex: currentSelection.index - 1)
                runtimeProvider(currentSelection.paneID)?.findPreviousInGlobalSearch()
                return
            }
        }

        let target = nextPaneTarget(from: currentTargetIndex, direction: direction, in: liveTargets)
        guard let target else {
            return
        }

        if target.paneID == currentSelection.paneID {
            switch direction {
            case .next:
                setSelection(paneID: currentSelection.paneID, selectedIndex: 0)
                runtimeProvider(currentSelection.paneID)?.findNextInGlobalSearch()
            case .previous:
                let lastIndex = max(0, currentPaneState.total - 1)
                setSelection(paneID: currentSelection.paneID, selectedIndex: lastIndex)
                runtimeProvider(currentSelection.paneID)?.findPreviousInGlobalSearch()
            }
            return
        }

        runtimeProvider(currentSelection.paneID)?.resetGlobalSearchSelection()
        let targetPaneState = paneResults[target.paneID] ?? PaneResultState()
        switch direction {
        case .next:
            navigateToTarget(target.worklaneID, target.paneID) { [weak self] in
                self?.completeCrossTargetNavigation(to: target.paneID, selectedIndex: 0, direction: .next)
            }
        case .previous:
            let lastIndex = max(0, targetPaneState.total - 1)
            navigateToTarget(target.worklaneID, target.paneID) { [weak self] in
                self?.completeCrossTargetNavigation(to: target.paneID, selectedIndex: lastIndex, direction: .previous)
            }
        }
    }

    private func navigateFromUnselected(direction: Direction, liveTargets: [GlobalSearchTarget]) {
        let target: GlobalSearchTarget? = switch direction {
        case .next:
            liveTargets.first { (paneResults[$0.paneID]?.total ?? 0) > 0 }
        case .previous:
            liveTargets.last { (paneResults[$0.paneID]?.total ?? 0) > 0 }
        }

        guard let target else {
            return
        }

        let paneState = paneResults[target.paneID] ?? PaneResultState()

        switch direction {
        case .next:
            navigateToTarget(target.worklaneID, target.paneID) { [weak self] in
                self?.completeCrossTargetNavigation(to: target.paneID, selectedIndex: 0, direction: .next)
            }
        case .previous:
            let lastIndex = max(0, paneState.total - 1)
            navigateToTarget(target.worklaneID, target.paneID) { [weak self] in
                self?.completeCrossTargetNavigation(to: target.paneID, selectedIndex: lastIndex, direction: .previous)
            }
        }
    }

    private func nextPaneTarget(
        from currentIndex: Int,
        direction: Direction,
        in liveTargets: [GlobalSearchTarget]
    ) -> GlobalSearchTarget? {
        guard !liveTargets.isEmpty else {
            return nil
        }

        switch direction {
        case .next:
            for offset in 1...liveTargets.count {
                let index = (currentIndex + offset) % liveTargets.count
                let target = liveTargets[index]
                if (paneResults[target.paneID]?.total ?? 0) > 0 {
                    return target
                }
            }
        case .previous:
            for offset in 1...liveTargets.count {
                let index = (currentIndex - offset + liveTargets.count) % liveTargets.count
                let target = liveTargets[index]
                if (paneResults[target.paneID]?.total ?? 0) > 0 {
                    return target
                }
            }
        }

        return nil
    }

    private func dispatchQueryUpdate(_ needle: String) {
        queryUpdateWorkItem = nil
        pendingPaneIDsAwaitingTotals = []
        for target in frozenTargets {
            guard let runtime = runtimeProvider(target.paneID) else {
                continue
            }

            pendingPaneIDsAwaitingTotals.insert(target.paneID)
            runtime.beginGlobalSearch { [weak self] paneID, event in
                self?.handleSearchEvent(for: paneID, event: event)
            }
            runtime.updateGlobalSearchNeedle(needle)
        }
    }

    private func captureFrozenTargets() {
        frozenTargets = orderedTargetsProvider()
        for target in frozenTargets where paneResults[target.paneID] == nil {
            paneResults[target.paneID] = PaneResultState()
        }
    }

    private func clearPaneResults() {
        paneResults = Dictionary(
            uniqueKeysWithValues: frozenTargets.map { ($0.paneID, PaneResultState()) }
        )
        currentSelection = nil
    }

    private func recomputeTotal() {
        state.total = paneResults.values.reduce(into: 0) { partialResult, paneState in
            partialResult += paneState.total
        }
        if state.total == 0 {
            state.selected = -1
        }
    }

    private func globalOrdinal(for paneID: PaneID, selectedIndex: Int) -> Int {
        var offset = 0
        for target in frozenTargets {
            guard let paneState = paneResults[target.paneID] else {
                continue
            }

            if target.paneID == paneID {
                return offset + selectedIndex
            }

            offset += paneState.total
        }

        return -1
    }

    private func setSelection(paneID: PaneID, selectedIndex: Int) {
        for targetPaneID in paneResults.keys {
            paneResults[targetPaneID]?.selected = targetPaneID == paneID ? selectedIndex : -1
        }
        currentSelection = Selection(paneID: paneID, index: selectedIndex)
        state.selected = globalOrdinal(for: paneID, selectedIndex: selectedIndex)
    }

    private func completeCrossTargetNavigation(
        to paneID: PaneID,
        selectedIndex: Int,
        direction: Direction
    ) {
        guard state.hasRememberedSearch else {
            return
        }

        let livePaneIDs = Set(frozenTargets.map(\.paneID))
        guard livePaneIDs.contains(paneID) else {
            return
        }

        setSelection(paneID: paneID, selectedIndex: selectedIndex)
        switch direction {
        case .next:
            runtimeProvider(paneID)?.findNextInGlobalSearch()
        case .previous:
            runtimeProvider(paneID)?.findPreviousInGlobalSearch()
        }
    }

    private func flushPendingQueryUpdateIfNeeded() {
        guard queryUpdateWorkItem != nil else {
            return
        }

        queryUpdateWorkItem?.cancel()
        queryUpdateWorkItem = nil
        dispatchQueryUpdate(state.needle)
    }

    private func performPendingNavigationIfReady() {
        guard pendingPaneIDsAwaitingTotals.isEmpty,
              let direction = pendingNavigationDirection,
              state.total > 0 else {
            return
        }

        pendingNavigationDirection = nil
        navigate(direction)
    }
}
