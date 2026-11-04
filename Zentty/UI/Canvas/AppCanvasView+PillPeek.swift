import AppKit

/// The pill peek between the pill bar and the float layer: the bar says
/// which pill is hovered, the layer lends that minimized pane's container,
/// the peek draws it like a PiP above the pill (see `PillPeekView`).
extension AppCanvasView {
    /// Minimized panes the peek draws live (kept un-occluded).
    var pillPeekedPaneIDs: Set<PaneID> {
        pillPeekView.visiblePaneID.map { [$0] } ?? []
    }

    func wirePillPeek() {
        pillPeekView.lender = { [weak floatLayerView] paneID in
            floatLayerView?.lendPeekContainer(paneID)
        }
        pillPeekView.returner = { [weak floatLayerView] loan, pip in
            if let floatLayerView {
                floatLayerView.takeBackPeekContainer(loan, from: pip)
            } else {
                pip.abandonHostedContainer()
                loan.container.removeFromSuperview()
            }
        }
        pillPeekView.onVisiblePaneChanged = { [weak self] in
            self?.onPillPeekChanged?()
        }
    }

    func updatePeek(_ item: PillBarItem?, pillFrame: CGRect) {
        // No peek while the bar is hidden or faded out (worklane peek).
        guard let item, !pillBarView.isHidden, pillBarView.alphaValue > 0 else {
            pillPeekView.hide()
            return
        }
        pillPeekView.show(
            item,
            above: convert(pillFrame, from: pillBarView),
            in: floatLayerView.frame,
            pipWidth: floatLayerView.pipWidth
        )
    }
}
