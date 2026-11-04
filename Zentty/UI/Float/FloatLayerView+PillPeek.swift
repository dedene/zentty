import AppKit

/// A minimized float's live container, lent to the pill peek.
@MainActor
struct PillPeekLoan {
    let paneID: PaneID
    let container: PaneContainerView
    /// The runtime it was lent on: gone from the registry once the pane closed.
    let runtime: PaneRuntime
    /// The float's unscaled size: the grid the terminal keeps while lent.
    let contentSize: CGSize
}

/// Lending a minimized float's terminal to the pill peek. A minimized pane
/// has no container in this layer; the peek gets a fresh one on the shared
/// runtime (it borrows the pane's host view, like any float) and the layer
/// takes it back before it mounts the pane again (restore, auto-pop).
///
/// Viewport order (spike 0a), the same as a PiP's: the container is primed
/// unscaled at the float size while it sits here, then the peek suspends it
/// under `.pillPeek` before it scales it. Coming back, it is re-parked here
/// unscaled at that size before `.pillPeek` lets go, so sync never resumes
/// at the scaled size (nor out of a window, where the grid is a guess).
extension FloatLayerView {
    /// A container for minimized `paneID`, primed at its float size, or nil
    /// when it is not a minimized float of this layer. The caller hosts it
    /// in the same pass (`PipContainerView.host(_:contentSize:suspendedBy:)`
    /// with `.pillPeek`), so it is never drawn here.
    func lendPeekContainer(_ paneID: PaneID) -> PillPeekLoan? {
        guard containers[paneID] == nil, bounds.width > 0, bounds.height > 0,
              let float = content.floats.first(where: { $0.pane.id == paneID }),
              case .minimized = float.mode else {
            return nil
        }
        let contentSize = FloatLayerLayout.floatFrame(for: float, canvas: bounds).size
        // Its leaving copy (the morph into the pill) still holds the terminal.
        finishDeparture(paneID)
        let runtime = runtimeRegistry.runtime(for: float.pane)
        let container = PaneContainerView(
            pane: float.pane,
            width: contentSize.width,
            height: contentSize.height,
            emphasis: 1,
            isFocused: false,
            runtime: runtime,
            theme: currentTheme,
            initialViewportSyncSuspended: true,
            initialViewportSuspensionOwner: .pillPeek
        )
        container.showPaneBorders = showPaneBorders
        container.smoothScrollingEnabled = smoothScrollingEnabled
        container.chromeKind = .pip
        container.render(
            pane: float.pane,
            emphasis: 1,
            isFocused: false,
            borderContext: content.borderContextByPaneID[paneID],
            worklaneColor: content.worklaneColor,
            animated: false
        )
        container.activateSessionIfNeeded()
        primeUnscaled(container, contentSize: contentSize, owner: .pillPeek)
        // Display only: the terminal reports no pointer and sets no cursor.
        container.setFloatMouseOcclusionRects([container.bounds])
        container.setFloatCursorExclusionRects([container.bounds])
        return PillPeekLoan(paneID: paneID, container: container, runtime: runtime, contentSize: contentSize)
    }

    /// Takes a lent container back out of `pip` and drops it. A live pane is
    /// re-parked here unscaled first, then `.pillPeek` lets go; a closed one
    /// (its runtime gone) is just dropped.
    func takeBackPeekContainer(_ loan: PillPeekLoan, from pip: PipContainerView) {
        let container = loan.container
        let isAlive = runtimeRegistry.runtime(for: loan.paneID) === loan.runtime
        if isAlive, window != nil, pip.hostedContainer === container {
            container.frame = CGRect(origin: .zero, size: loan.contentSize)
            container.removeFromSuperview()
            addSubview(container, positioned: .below, relativeTo: nil)
            pip.relinquishHostedContainer()
        } else {
            pip.abandonHostedContainer()
        }
        container.prepareForRemoval()
        container.removeFromSuperview()
    }
}
