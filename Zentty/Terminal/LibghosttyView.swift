import AppKit
import QuartzCore

@MainActor
final class LibghosttyView: NSView, TerminalFocusReporting {
    private var surfaceController: (any LibghosttySurfaceControlling)?
    var onFocusDidChange: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        metalLayer.contentsScale = currentScaleFactor
        return metalLayer
    }

    override func layout() {
        super.layout()
        syncViewport()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncViewport()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = currentScaleFactor
        syncViewport()
    }

    override func becomeFirstResponder() -> Bool {
        surfaceController?.setFocused(true)
        onFocusDidChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        surfaceController?.setFocused(false)
        onFocusDidChange?(false)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    func bind(surfaceController: any LibghosttySurfaceControlling) {
        self.surfaceController = surfaceController
    }

    var currentDisplayID: UInt32? {
        guard let screen = window?.screen ?? NSScreen.main else {
            return nil
        }

        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.uint32Value
        }

        return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }

    private var currentScaleFactor: CGFloat {
        window?.backingScaleFactor ?? layer?.contentsScale ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    private func syncViewport() {
        guard bounds.width > 0, bounds.height > 0 else {
            return
        }

        let backingBounds = convertToBacking(bounds)
        let viewportSize = CGSize(
            width: max(1, backingBounds.width),
            height: max(1, backingBounds.height)
        )

        surfaceController?.updateViewport(
            size: viewportSize,
            scale: currentScaleFactor,
            displayID: currentDisplayID
        )
    }
}
