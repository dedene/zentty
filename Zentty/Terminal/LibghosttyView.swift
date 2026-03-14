import AppKit
import QuartzCore

final class LibghosttyView: NSView, TerminalFocusReporting {
    private var surfaceController: (any LibghosttySurfaceControlling)?
    private var keyTextAccumulator = ""
    private var markedTextStorage = ""
    private var markedTextSelection = NSRange(location: NSNotFound, length: 0)
    private var selectedTextStorageRange = NSRange(location: NSNotFound, length: 0)
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

    override func keyDown(with event: NSEvent) {
        guard let surfaceController else {
            super.keyDown(with: event)
            return
        }

        keyTextAccumulator = ""
        interpretKeyEvents([event])
        let keyText = keyTextAccumulator.isEmpty ? nil : keyTextAccumulator
        _ = surfaceController.sendKey(
            event: event,
            action: event.isARepeat ? .repeatPress : .press,
            text: keyText,
            composing: hasMarkedText()
        )
        keyTextAccumulator = ""
    }

    override func keyUp(with event: NSEvent) {
        guard let surfaceController else {
            super.keyUp(with: event)
            return
        }

        _ = surfaceController.sendKey(event: event, action: .release, text: nil, composing: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surfaceController else {
            super.flagsChanged(with: event)
            return
        }

        _ = surfaceController.sendKey(event: event, action: .press, text: nil, composing: false)
    }

    nonisolated override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    nonisolated override func doCommand(by selector: Selector) {}

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

extension LibghosttyView: NSTextInputClient {
    nonisolated func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else if let plain = string as? String {
            text = plain
        } else {
            text = "\(string)"
        }

        MainActor.assumeIsolated {
            self.markedTextStorage = ""
            self.markedTextSelection = NSRange(location: NSNotFound, length: 0)
            self.selectedTextStorageRange = NSRange(location: NSNotFound, length: 0)

            guard !text.isEmpty else {
                return
            }

            if self.keyTextAccumulator.isEmpty, NSApp.currentEvent == nil {
                self.surfaceController?.sendText(text)
                return
            }

            self.keyTextAccumulator += text
        }
    }

    nonisolated func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else if let plain = string as? String {
            text = plain
        } else {
            text = "\(string)"
        }

        MainActor.assumeIsolated {
            self.markedTextStorage = text
            self.markedTextSelection = selectedRange
            self.selectedTextStorageRange = replacementRange
        }
    }

    nonisolated func unmarkText() {
        MainActor.assumeIsolated {
            self.markedTextStorage = ""
            self.markedTextSelection = NSRange(location: NSNotFound, length: 0)
        }
    }

    nonisolated func selectedRange() -> NSRange {
        MainActor.assumeIsolated {
            self.selectedTextStorageRange
        }
    }

    nonisolated func markedRange() -> NSRange {
        MainActor.assumeIsolated {
            !self.markedTextStorage.isEmpty
                ? NSRange(location: 0, length: self.markedTextStorage.utf16.count)
                : NSRange(location: NSNotFound, length: 0)
        }
    }

    nonisolated func hasMarkedText() -> Bool {
        MainActor.assumeIsolated {
            !self.markedTextStorage.isEmpty
        }
    }

    nonisolated func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
        return nil
    }

    nonisolated func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    nonisolated func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = MainActor.assumeIsolated {
            guard let window = self.window else {
                return NSRect.zero
            }

            let rectInWindow = self.convert(self.bounds, to: nil)
            return window.convertToScreen(rectInWindow)
        }
        actualRange?.pointee = range
        return rect
    }

    nonisolated func characterIndex(for point: NSPoint) -> Int {
        0
    }
}
