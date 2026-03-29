import AppKit

final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing bufferingType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: bufferingType, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.transient, .moveToActiveSpace]
    }
}
