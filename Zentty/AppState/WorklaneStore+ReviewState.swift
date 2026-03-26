import Foundation

extension WorklaneStore {
    func updateReviewResolution(paneID: PaneID, resolution: WorklaneReviewResolution) {
        guard let worklaneIndex = worklanes.firstIndex(where: { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var worklane = worklanes[worklaneIndex]
        let previousState = worklane.auxiliaryStateByPaneID[paneID]?.reviewState
        if resolution.updatePolicy == .preserveExistingOnEmpty,
           resolution.reviewState == nil {
            return
        }
        guard previousState != resolution.reviewState else {
            return
        }

        if let reviewState = resolution.reviewState {
            worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].reviewState = reviewState
        } else {
            worklane.auxiliaryStateByPaneID[paneID]?.reviewState = nil
        }

        recomputePresentation(for: paneID, in: &worklane)
        worklanes[worklaneIndex] = worklane
        notify(.auxiliaryStateUpdated(worklane.id, paneID))
    }

    func updateReviewState(paneID: PaneID, reviewState: WorklaneReviewState?) {
        guard let worklaneIndex = worklanes.firstIndex(where: { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var worklane = worklanes[worklaneIndex]
        let previousState = worklane.auxiliaryStateByPaneID[paneID]?.reviewState
        guard previousState != reviewState else {
            return
        }

        if let reviewState {
            worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].reviewState = reviewState
        } else {
            worklane.auxiliaryStateByPaneID[paneID]?.reviewState = nil
        }

        recomputePresentation(for: paneID, in: &worklane)
        worklanes[worklaneIndex] = worklane
        notify(.auxiliaryStateUpdated(worklane.id, paneID))
    }
}
