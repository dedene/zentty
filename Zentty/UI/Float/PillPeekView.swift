import AppKit

/// Hover preview above a pill: the minimized float's live terminal, drawn
/// exactly like a PiP. On hover the float layer lends the pane a container
/// (`lender`); it is hosted in a display-only `PipContainerView` (bounds
/// scaling, same chrome and status strip) with viewport sync suspended under
/// `.pillPeek`, so the PTY never sees the scaled size. While it shows, the
/// pane is un-occluded (`visiblePaneID`, see `PaneActivityResolver`).
/// Hover-out occludes it again, fades out, then hands the container back
/// (`returner`). `PillPeekLease` decides the steps.
///
/// Display only: hit-transparent, so clicks reach the pill below or
/// whatever else is there; it never takes focus or keys.
@MainActor
final class PillPeekView: NSView {
    /// Gap between the pill's top edge and the peek.
    static let anchorGap: CGFloat = 8
    static let edgeInset: CGFloat = 8
    static let fadeDuration: TimeInterval = 0.15

    /// Borrows a minimized pane's container (nil: nothing to show).
    var lender: ((PaneID) -> PillPeekLoan?)?
    /// Takes a lent container back out of the PiP that hosted it.
    var returner: ((PillPeekLoan, PipContainerView) -> Void)?
    /// `visiblePaneID` changed on a hover (the canvas re-pushes surface
    /// activities). Not called from `release(keeping:)`: that runs inside a
    /// canvas render, which updates activities itself.
    var onVisiblePaneChanged: (() -> Void)?

    private(set) var lease = PillPeekLease()
    private(set) var loan: PillPeekLoan?
    private(set) var pip: PipContainerView?
    private var theme = ZenttyTheme.fallback(for: nil)
    private var status: PillBarItem?
    private var fadeGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The PiP's shadow and glow draw outside its frame.
        layer?.masksToBounds = false
        autoresizesSubviews = false
        isHidden = true
        alphaValue = 0
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// The pane shown live, un-occluded; nil while idle or fading out.
    var visiblePaneID: PaneID? {
        lease.visiblePaneID
    }

    /// The pane whose container the peek holds.
    var paneID: PaneID? {
        lease.heldPaneID
    }

    func apply(theme: ZenttyTheme) {
        self.theme = theme
        pip?.configure(status: status, theme: theme)
        loan?.container.apply(theme: theme, animated: false)
    }

    /// Shows `item`'s pane live above `anchor` (the pill's frame in the
    /// superview's coordinates), kept inside `canvas`, as a PiP `pipWidth`
    /// wide. Showing the same pane again only moves it and refreshes status.
    func show(_ item: PillBarItem, above anchor: CGRect, in canvas: CGRect, pipWidth: CGFloat) {
        status = item
        let wasVisible = visiblePaneID
        run(lease.hover(item.paneID))
        guard let loan, let pip, loan.paneID == item.paneID else { return }
        pip.configure(status: item, theme: theme)
        let size = FloatLayout.pipSize(floatSize: loan.contentSize, width: pipWidth)
        frame = Self.frame(size: size, above: anchor, in: canvas)
        pip.apply(frame: CGRect(origin: .zero, size: size), contentSize: loan.contentSize)
        if visiblePaneID != wasVisible {
            onVisiblePaneChanged?()
        }
    }

    /// Hover-out: occludes the pane, fades out, then hands it back.
    func hide() {
        let wasVisible = visiblePaneID
        run(lease.hover(nil))
        if visiblePaneID != wasVisible {
            onVisiblePaneChanged?()
        }
    }

    /// Hands the held pane back right away (no fade) unless it is still one
    /// of `pillIDs`. Call before the float layer renders: it may mount it.
    func release(keeping pillIDs: Set<PaneID>) {
        let steps = lease.release(keeping: pillIDs)
        guard !steps.isEmpty else { return }
        run(steps)
        fadeGeneration += 1
        alphaValue = 0
        isHidden = true
    }

    /// Refreshes the shown pane's status strip (`PillBarItem` by pane).
    func updateStatus(_ items: [PillBarItem]) {
        guard let paneID, let item = items.first(where: { $0.paneID == paneID }) else { return }
        status = item
        pip?.configure(status: item, theme: theme)
    }

    /// Above the pill, right edges aligned, kept inside `container` (on top
    /// when there is no room above).
    static func frame(size: CGSize, above anchor: CGRect, in container: CGRect) -> CGRect {
        var x = anchor.maxX - size.width
        x = min(x, container.maxX - edgeInset - size.width)
        x = max(x, container.minX + edgeInset)
        var y = anchor.maxY + anchorGap
        y = min(y, container.maxY - edgeInset - size.height)
        y = max(y, container.minY)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    // MARK: - Steps

    private func run(_ steps: [PillPeekLease.Step]) {
        for step in steps {
            switch step {
            case .lend(let paneID):
                lend(paneID)
            case .giveBack(let paneID):
                giveBack(paneID)
            case .fadeIn:
                guard loan != nil else { continue }
                fade(in: true)
            case .fadeOut:
                fade(in: false)
            }
        }
    }

    private func lend(_ paneID: PaneID) {
        guard let loan = lender?(paneID) else {
            lease.lendFailed(paneID)
            fadeGeneration += 1
            alphaValue = 0
            isHidden = true
            return
        }
        let pip = PipContainerView(paneID: paneID, isDisplayOnly: true)
        addSubview(pip)
        // Same pass as the prime: never drawn unscaled.
        pip.host(loan.container, contentSize: loan.contentSize, suspendedBy: .pillPeek)
        pip.apply(frame: CGRect(origin: .zero, size: bounds.size), contentSize: loan.contentSize)
        self.loan = loan
        self.pip = pip
    }

    private func giveBack(_ paneID: PaneID) {
        guard let loan, loan.paneID == paneID, let pip else { return }
        self.loan = nil
        self.pip = nil
        if let returner {
            returner(loan, pip)
        } else {
            pip.abandonHostedContainer()
            loan.container.removeFromSuperview()
        }
        pip.removeFromSuperview()
    }

    // MARK: - Fade

    private func fade(in visible: Bool) {
        fadeGeneration += 1
        let generation = fadeGeneration
        if visible {
            isHidden = false
        }
        guard window != nil, !FloatMotion.reduceMotion else {
            alphaValue = visible ? 1 : 0
            isHidden = !visible
            if !visible {
                fadeOutFinished()
            }
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeIn)
            self.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: {
            MainActorShim.assumeIsolated {
                guard generation == self.fadeGeneration else { return }
                self.isHidden = !visible
                if !visible {
                    self.fadeOutFinished()
                }
            }
        })
    }

    private func fadeOutFinished() {
        guard case .leaving(let paneID) = lease.phase else { return }
        run(lease.fadeOutFinished(paneID))
    }
}
