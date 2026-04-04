import AppKit

/// Semi-transparent ghost of the dragged pane shown at the original position
/// when Option is held (duplicate mode indicator).
@MainActor
final class PaneDragGhostView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
