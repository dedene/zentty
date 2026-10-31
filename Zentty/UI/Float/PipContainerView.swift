import AppKit

/// Hosts a PiP: the float's live `PaneContainerView` at its full float size,
/// drawn smaller by bounds scaling (`frame` = PiP frame, `bounds` = float
/// size). The terminal's viewport sync stays suspended while it is here, so
/// the grid keeps the float's columns and rows.
///
/// Owns every click: the scaled terminal must never receive mouse events at
/// scaled coordinates. Minimal for now; gestures, legend and status come later.
@MainActor
final class PipContainerView: NSView {
    let paneID: PaneID
    var onClicked: ((PaneID) -> Void)?
    private(set) var contentSize: CGSize = .zero
    private(set) weak var hostedContainer: PaneContainerView?

    init(paneID: PaneID) {
        self.paneID = paneID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Enter PiP: freezes the grid (the `.pip` suspension owner) before the
    /// container is re-parented and scaled, then hosts it at `contentSize`.
    func host(_ container: PaneContainerView, contentSize: CGSize) {
        guard container.superview !== self else { return }
        container.suspendTerminalViewportSync(by: .pip)
        container.removeFromSuperview()
        container.frame = CGRect(origin: .zero, size: contentSize)
        addSubview(container)
        hostedContainer = container
    }

    /// Leave PiP: call once the container sits at its final unscaled frame
    /// elsewhere. Drops the PiP's suspension; sync resumes unless another
    /// owner (a lift still landing) holds it.
    func relinquishHostedContainer() {
        hostedContainer?.resumeTerminalViewportSync(by: .pip)
        hostedContainer = nil
    }

    /// Places the PiP at `frame` and scales `contentSize` into it. Bounds must
    /// be re-set after every frame change, or AppKit resets the scale.
    func apply(frame: CGRect, contentSize: CGSize) {
        self.contentSize = contentSize
        if self.frame != frame {
            self.frame = frame
        }
        let scaledBounds = CGRect(origin: .zero, size: contentSize)
        if bounds != scaledBounds {
            bounds = scaledBounds
        }
        for subview in subviews where subview.frame != scaledBounds {
            subview.frame = scaledBounds
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else {
            return nil
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onClicked?(paneID)
    }

    override func scrollWheel(with event: NSEvent) {
        // Swallowed: a scaled terminal must not scroll from here.
    }
}
