import AppKit
import GhosttyKit
import QuartzCore

@MainActor
protocol TerminalViewportSyncControlling: AnyObject {
    func setViewportSyncSuspended(_ suspended: Bool)
}

final class LibghosttyView: NSView, TerminalFocusReporting {
    private struct ViewportSignature: Equatable {
        let size: CGSize
        let scale: CGFloat
        let displayID: UInt32?
    }

    private enum BindingAction {
        static let copyToClipboard = "copy_to_clipboard"
        static let pasteFromClipboard = "paste_from_clipboard"
        static let selectAll = "select_all"
    }

    private static let terminalCommandSelectors: [Selector] = [
        #selector(NSResponder.cancelOperation(_:)),
        #selector(NSResponder.deleteBackward(_:)),
        #selector(NSResponder.deleteForward(_:)),
        #selector(NSResponder.insertBacktab(_:)),
        #selector(NSResponder.insertNewline(_:)),
        #selector(NSResponder.insertTab(_:)),
        #selector(NSResponder.moveDown(_:)),
        #selector(NSResponder.moveLeft(_:)),
        #selector(NSResponder.moveRight(_:)),
        #selector(NSResponder.moveToBeginningOfDocument(_:)),
        #selector(NSResponder.moveToBeginningOfLine(_:)),
        #selector(NSResponder.moveToEndOfDocument(_:)),
        #selector(NSResponder.moveToEndOfLine(_:)),
        #selector(NSResponder.moveUp(_:)),
        #selector(NSResponder.pageDown(_:)),
        #selector(NSResponder.pageUp(_:)),
        #selector(NSResponder.scrollPageDown(_:)),
        #selector(NSResponder.scrollPageUp(_:)),
    ]

    private var surfaceController: (any LibghosttySurfaceControlling)?
    private var lastViewportSignature: ViewportSignature?
    private var isViewportSyncSuspended = false
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = currentScaleFactor
        CATransaction.commit()
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
        forwardMousePosition(event)
        surfaceController?.sendMouseButton(
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_LEFT,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }

    override func mouseDragged(with event: NSEvent) {
        forwardMousePosition(event)
    }

    override func mouseUp(with event: NSEvent) {
        forwardMousePosition(event)
        surfaceController?.sendMouseButton(
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_LEFT,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }

    override func scrollWheel(with event: NSEvent) {
        if Self.shouldRouteScrollToPaneSwitch(event) {
            if let nextResponder {
                nextResponder.scrollWheel(with: event)
            } else {
                super.scrollWheel(with: event)
            }
            return
        }

        guard let surfaceController else {
            super.scrollWheel(with: event)
            return
        }

        surfaceController.sendMouseScroll(
            x: event.scrollingDeltaX,
            y: event.scrollingDeltaY,
            precision: event.hasPreciseScrollingDeltas,
            momentum: event.momentumPhase
        )
    }

    override func keyDown(with event: NSEvent) {
        guard let surfaceController else {
            super.keyDown(with: event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option) && !hasMarkedText() {
            let controlText = event.charactersIgnoringModifiers ?? event.characters
            let handled = surfaceController.sendKey(
                event: event,
                action: event.isARepeat ? .repeatPress : .press,
                text: controlText,
                composing: false
            )
            if handled {
                return
            }
        }

        keyTextAccumulator = ""
        interpretKeyEvents([event])
        let keyText = keyTextAccumulator.isEmpty ? fallbackText(for: event) : keyTextAccumulator
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

    nonisolated override func doCommand(by selector: Selector) {
        MainActor.assumeIsolated {
            // Terminal navigation/editing commands should be handled by Ghostty via keycode,
            // not converted into printable fallback text by AppKit.
            if Self.terminalCommandSelectors.contains(where: { $0 == selector }) {
                self.keyTextAccumulator = ""
            }
        }
    }

    @IBAction func copy(_ sender: Any?) {
        _ = surfaceController?.performBindingAction(BindingAction.copyToClipboard)
    }

    @IBAction func paste(_ sender: Any?) {
        _ = surfaceController?.performBindingAction(BindingAction.pasteFromClipboard)
    }

    @IBAction override func selectAll(_ sender: Any?) {
        _ = surfaceController?.performBindingAction(BindingAction.selectAll)
    }

    func bind(surfaceController: any LibghosttySurfaceControlling) {
        self.surfaceController = surfaceController
    }

    func setViewportSyncSuspended(_ suspended: Bool) {
        guard isViewportSyncSuspended != suspended else {
            return
        }

        isViewportSyncSuspended = suspended
        if !suspended {
            syncViewport()
        }
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

        if isViewportSyncSuspended {
            return
        }

        let backingBounds = convertToBacking(bounds)
        syncLayerGeometry(backingBounds: backingBounds)
        let viewportSize = CGSize(
            width: max(1, backingBounds.width),
            height: max(1, backingBounds.height)
        )
        let viewportSignature = ViewportSignature(
            size: viewportSize,
            scale: currentScaleFactor,
            displayID: currentDisplayID
        )

        guard viewportSignature != lastViewportSignature else {
            return
        }

        lastViewportSignature = viewportSignature
        surfaceController?.updateViewport(
            size: viewportSignature.size,
            scale: viewportSignature.scale,
            displayID: viewportSignature.displayID
        )
        surfaceController?.refresh()
    }

    private func syncLayerGeometry(backingBounds: CGRect) {
        let scale = currentScaleFactor
        let drawableSize = CGSize(
            width: max(1, floor(backingBounds.width)),
            height: max(1, floor(backingBounds.height))
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        if let metalLayer = layer as? CAMetalLayer, metalLayer.drawableSize != drawableSize {
            metalLayer.drawableSize = drawableSize
        }
        CATransaction.commit()
    }

    private func fallbackText(for event: NSEvent) -> String? {
        LibghosttySurface.textForKeyEvent(event)
    }

    private static func sanitizedInputText(_ text: String) -> String? {
        guard !text.isEmpty else {
            return nil
        }

        let scalars = text.unicodeScalars
        if scalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
            return nil
        }

        if scalars.allSatisfy({ $0.value >= 0xF700 && $0.value <= 0xF8FF }) {
            return nil
        }

        return text
    }

    private static func shouldRouteScrollToPaneSwitch(_ event: NSEvent) -> Bool {
        let horizontalDelta = abs(event.scrollingDeltaX)
        let verticalDelta = abs(event.scrollingDeltaY)

        if horizontalDelta > verticalDelta, horizontalDelta > 0 {
            return true
        }

        let deviceIndependentFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return !event.hasPreciseScrollingDeltas
            && deviceIndependentFlags.contains(.shift)
            && verticalDelta > 0
            && verticalDelta >= horizontalDelta
    }

    private func forwardMousePosition(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let position = CGPoint(x: point.x, y: bounds.height - point.y)
        surfaceController?.sendMousePosition(
            position,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }
}

@MainActor
extension LibghosttyView: TerminalViewportSyncControlling {}

extension LibghosttyView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return surfaceController?.hasSelection() ?? false
        default:
            return true
        }
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

            guard let text = Self.sanitizedInputText(text) else {
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
