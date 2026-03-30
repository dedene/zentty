import AppKit
import QuartzCore

/// A layer-hosting view for the drag preview. Because it owns its layer
/// (rather than being merely layer-backed), AppKit does not fight our
/// anchorPoint / position / transform / shadow mutations.
@MainActor
final class PaneDragFloatingContainer: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-hosting: we own the layer, AppKit stays hands-off.
        let hostLayer = CALayer()
        hostLayer.masksToBounds = false
        self.layer = hostLayer
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
