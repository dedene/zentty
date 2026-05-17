import AppKit

@MainActor
protocol PaneSearchHUDViewDelegate: AnyObject {
    func paneSearchHUDView(_ hudView: PaneSearchHUDView, didChangeQuery query: String)
    func paneSearchHUDViewDidRequestNext(_ hudView: PaneSearchHUDView)
    func paneSearchHUDViewDidRequestPrevious(_ hudView: PaneSearchHUDView)
    func paneSearchHUDViewDidRequestHide(_ hudView: PaneSearchHUDView)
    func paneSearchHUDViewDidRequestClose(_ hudView: PaneSearchHUDView)
    func paneSearchHUDViewFrameDidChange(_ hudView: PaneSearchHUDView)
    func paneSearchHUDView(_ hudView: PaneSearchHUDView, didSnapTo corner: PaneSearchHUDCorner)
}

@MainActor
final class PaneSearchHUDView: NSView {
    enum Layout {
        static let size = CGSize(width: 336, height: 42)
        static let contentInset = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        static let interItemSpacing: CGFloat = 8
        static let closeButtonSize = CGSize(width: 22, height: 22)
        static let navigationButtonSize = CGSize(width: 22, height: 22)
        static let cornerInset: CGFloat = 14
        static let snapAnimationDuration: TimeInterval = 0.22
    }

    private let countLabel = NSTextField(labelWithString: "0/0")
    private let queryField = PaneSearchTextField()
    private let nextButton = PaneSearchHUDButton()
    private let previousButton = PaneSearchHUDButton()
    private let closeButton = PaneSearchHUDButton()
    private let dragGestureRecognizer = NSPanGestureRecognizer()
    private var isProgrammaticFieldUpdate = false
    private var dragStartOrigin = CGPoint.zero
    private var isDragging = false
    private var isSnapAnimationInFlight = false
    private var snapAnimationRunnerForTesting: ((CGPoint, @escaping () -> Void) -> Void)?

    weak var delegate: (any PaneSearchHUDViewDelegate)?
    var containerBoundsProvider: (() -> CGRect)?
    private(set) var corner: PaneSearchHUDCorner = .topTrailing

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(search: PaneSearchState) {
        corner = search.hudCorner
        isHidden = !search.isHUDVisible
        countLabel.stringValue = countText(for: search)
        if queryField.stringValue != search.needle {
            isProgrammaticFieldUpdate = true
            queryField.stringValue = search.needle
            isProgrammaticFieldUpdate = false
        }
        invalidateInteractiveCursorRects()
    }

    func focusField(selectAll: Bool) {
        guard let window else {
            return
        }

        window.makeFirstResponder(queryField)
        if selectAll {
            queryField.currentEditor()?.selectAll(nil)
        }
    }

    func frame(for corner: PaneSearchHUDCorner, in bounds: CGRect) -> CGRect {
        let originX: CGFloat
        let originY: CGFloat

        switch corner {
        case .topLeading, .bottomLeading:
            originX = Layout.cornerInset
        case .topTrailing, .bottomTrailing:
            originX = max(Layout.cornerInset, bounds.width - Layout.cornerInset - Layout.size.width)
        }

        switch corner {
        case .topLeading, .topTrailing:
            originY = max(Layout.cornerInset, bounds.height - Layout.cornerInset - Layout.size.height)
        case .bottomLeading, .bottomTrailing:
            originY = Layout.cornerInset
        }

        return CGRect(origin: CGPoint(x: originX, y: originY), size: Layout.size).integral
    }

    var countTextForTesting: String {
        countLabel.stringValue
    }

    var nextButtonForTesting: PaneSearchHUDButton {
        nextButton
    }

    var previousButtonForTesting: PaneSearchHUDButton {
        previousButton
    }

    var closeButtonForTesting: PaneSearchHUDButton {
        closeButton
    }

    var queryFieldForTesting: NSTextField {
        queryField
    }

    var nextToolTipForTesting: String {
        nextButton.toolTip ?? ""
    }

    var previousToolTipForTesting: String {
        previousButton.toolTip ?? ""
    }

    var closeToolTipForTesting: String {
        closeButton.toolTip ?? ""
    }

    var backgroundColorTokenForTesting: String {
        layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.themeToken ?? ""
    }

    var borderColorTokenForTesting: String {
        layer?.borderColor.flatMap(NSColor.init(cgColor:))?.themeToken ?? ""
    }

    var countTextColorTokenForTesting: String {
        countLabel.textColor?.themeToken ?? ""
    }

    var queryTextColorTokenForTesting: String {
        queryField.textColor?.themeToken ?? ""
    }

    var nextButtonTintColorTokenForTesting: String {
        nextButton.contentTintColor?.themeToken ?? ""
    }

    var preservesInteractiveFrame: Bool {
        isDragging || isSnapAnimationInFlight
    }

    var isSnapAnimationInFlightForTesting: Bool {
        isSnapAnimationInFlight
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override var frame: NSRect {
        didSet {
            guard oldValue.origin != frame.origin else {
                return
            }

            delegate?.paneSearchHUDViewFrameDidChange(self)
        }
    }

    private func setup() {
        frame = CGRect(origin: .zero, size: Layout.size)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.borderWidth = 1
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: 8)

        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        queryField.placeholderString = "Find"
        queryField.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        queryField.focusRingType = .none
        queryField.bezelStyle = .roundedBezel
        queryField.isBordered = false
        queryField.drawsBackground = false
        queryField.delegate = self
        queryField.commandHandler = { [weak self] command in
            self?.handleFieldCommand(command)
        }
        queryField.translatesAutoresizingMaskIntoConstraints = false

        previousButton.image = NSImage(
            systemSymbolName: "chevron.up",
            accessibilityDescription: "Find Previous"
        )
        previousButton.target = self
        previousButton.action = #selector(handlePreviousButton)
        previousButton.translatesAutoresizingMaskIntoConstraints = false

        nextButton.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: "Find Next"
        )
        nextButton.target = self
        nextButton.action = #selector(handleNextButton)
        nextButton.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Close Find"
        )
        closeButton.target = self
        closeButton.action = #selector(handleCloseButton)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(queryField)
        addSubview(countLabel)
        addSubview(previousButton)
        addSubview(nextButton)
        addSubview(closeButton)

        dragGestureRecognizer.target = self
        dragGestureRecognizer.action = #selector(handlePanGesture(_:))
        dragGestureRecognizer.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(dragGestureRecognizer)

        NSLayoutConstraint.activate([
            queryField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.contentInset.left),
            queryField.centerYAnchor.constraint(equalTo: centerYAnchor),
            queryField.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -Layout.interItemSpacing),

            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: previousButton.leadingAnchor, constant: -Layout.interItemSpacing),
            countLabel.widthAnchor.constraint(equalToConstant: 42),

            previousButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            previousButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -4),
            previousButton.widthAnchor.constraint(equalToConstant: Layout.navigationButtonSize.width),
            previousButton.heightAnchor.constraint(equalToConstant: Layout.navigationButtonSize.height),

            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            nextButton.widthAnchor.constraint(equalToConstant: Layout.navigationButtonSize.width),
            nextButton.heightAnchor.constraint(equalToConstant: Layout.navigationButtonSize.height),

            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.contentInset.right),
            closeButton.widthAnchor.constraint(equalToConstant: Layout.closeButtonSize.width),
            closeButton.heightAnchor.constraint(equalToConstant: Layout.closeButtonSize.height),
        ])

        apply(theme: .fallback(for: nil), animated: false)
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        let textColor = theme.commandPaletteText
        let secondaryTextColor = theme.commandPaletteSecondaryText
        appearance = NSAppearance(named: theme.sidebarGlassAppearance.nsAppearanceName)
        queryField.applySearchHUDTheme(
            textColor: textColor,
            placeholderColor: secondaryTextColor.withAlphaComponent(0.72),
            placeholder: queryField.placeholderString ?? "Find"
        )
        countLabel.textColor = secondaryTextColor
        previousButton.contentTintColor = textColor.withAlphaComponent(0.78)
        nextButton.contentTintColor = textColor.withAlphaComponent(0.78)
        closeButton.contentTintColor = textColor.withAlphaComponent(0.86)

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = theme.commandPaletteBackground.cgColor
            self.layer?.borderColor = theme.commandPaletteBorder.cgColor
            self.layer?.shadowColor = theme.commandPaletteShadow.cgColor
        }
    }

    @objc
    private func handlePanGesture(_ recognizer: NSPanGestureRecognizer) {
        guard let superview else {
            return
        }

        switch recognizer.state {
        case .began:
            isDragging = true
            dragStartOrigin = frame.origin
        case .changed:
            let translation = recognizer.translation(in: superview)
            frame.origin = CGPoint(
                x: dragStartOrigin.x + translation.x,
                y: dragStartOrigin.y + translation.y
            ).rounded()
            invalidateInteractiveCursorRects()
        case .ended, .cancelled, .failed:
            isDragging = false
            snapToNearestCorner()
        default:
            break
        }
    }

    override func layout() {
        super.layout()
        invalidateInteractiveCursorRects()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateInteractiveCursorRects()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func countText(for search: PaneSearchState) -> String {
        guard !search.needle.isEmpty || search.selected >= 0 || search.total > 0 else {
            return ""
        }

        let totalText = search.total >= 0 ? String(search.total) : "?"
        if search.selected >= 0 {
            return "\(search.selected + 1)/\(totalText)"
        }

        return "-/\(totalText)"
    }

    private func handleFieldCommand(_ command: PaneSearchTextField.Command) {
        switch command {
        case .next:
            delegate?.paneSearchHUDViewDidRequestNext(self)
        case .previous:
            delegate?.paneSearchHUDViewDidRequestPrevious(self)
        case .escape:
            if queryField.stringValue.isEmpty {
                delegate?.paneSearchHUDViewDidRequestClose(self)
            } else {
                delegate?.paneSearchHUDViewDidRequestHide(self)
            }
        }
    }

    @objc
    private func handleCloseButton() {
        delegate?.paneSearchHUDViewDidRequestClose(self)
    }

    @objc
    private func handleNextButton() {
        delegate?.paneSearchHUDViewDidRequestNext(self)
    }

    @objc
    private func handlePreviousButton() {
        delegate?.paneSearchHUDViewDidRequestPrevious(self)
    }

    private func snapToNearestCorner() {
        guard let bounds = containerBoundsProvider?() else {
            return
        }

        let targetCorner = snappedCorner(in: bounds)
        let targetFrame = frame(for: targetCorner, in: bounds)

        guard frame.origin != targetFrame.origin else {
            corner = targetCorner
            delegate?.paneSearchHUDView(self, didSnapTo: targetCorner)
            return
        }

        animateSnap(to: targetFrame.origin) { [weak self] in
            guard let self else {
                return
            }

            self.frame = targetFrame
            self.corner = targetCorner
            self.isSnapAnimationInFlight = false
            self.invalidateInteractiveCursorRects()
            self.delegate?.paneSearchHUDView(self, didSnapTo: targetCorner)
        }
    }

    private func animateSnap(to targetOrigin: CGPoint, completion: @escaping () -> Void) {
        isSnapAnimationInFlight = true

        if let snapAnimationRunnerForTesting {
            snapAnimationRunnerForTesting(targetOrigin, completion)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.snapAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            self.animator().setFrameOrigin(targetOrigin)
        } completionHandler: {
            Task { @MainActor in
                completion()
            }
        }
    }

    private func invalidateInteractiveCursorRects() {
        guard let window else {
            return
        }

        for view in [self, queryField, previousButton, nextButton, closeButton] {
            window.invalidateCursorRects(for: view)
        }
    }

    private func snappedCorner(in bounds: CGRect) -> PaneSearchHUDCorner {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let prefersLeading = center.x < bounds.midX
        let prefersTop = center.y >= bounds.midY

        switch (prefersTop, prefersLeading) {
        case (true, true):
            return .topLeading
        case (true, false):
            return .topTrailing
        case (false, true):
            return .bottomLeading
        case (false, false):
            return .bottomTrailing
        }
    }

    func updateShortcutTooltips(_ shortcutManager: ShortcutManager) {
        previousButton.toolTip = CommandTooltipFormatter.title(
            "Find Previous",
            commandID: .findPrevious,
            shortcutManager: shortcutManager
        )
        nextButton.toolTip = CommandTooltipFormatter.title(
            "Find Next",
            commandID: .findNext,
            shortcutManager: shortcutManager
        )
        closeButton.toolTip = "Close Find"
    }

    func configureSnapAnimationForTesting(
        _ runner: @escaping (CGPoint, @escaping () -> Void) -> Void
    ) {
        snapAnimationRunnerForTesting = runner
    }

    func setOriginForTesting(_ origin: CGPoint) {
        frame.origin = origin
    }

    func snapToNearestCornerForTesting() {
        snapToNearestCorner()
    }
}

extension PaneSearchHUDView: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard !isProgrammaticFieldUpdate else {
            return
        }

        delegate?.paneSearchHUDView(self, didChangeQuery: queryField.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        queryField.handleCommand(selector: commandSelector)
    }
}

private extension CGPoint {
    func rounded() -> CGPoint {
        CGPoint(x: x.rounded(), y: y.rounded())
    }
}

@MainActor
final class PaneSearchTextField: NSTextField {
    enum Command {
        case next
        case previous
        case escape
    }

    var commandHandler: ((Command) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    func applySearchHUDTheme(textColor: NSColor, placeholderColor: NSColor, placeholder: String) {
        self.textColor = textColor
        placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: placeholderColor,
                .font: font ?? NSFont.systemFont(ofSize: 13, weight: .medium),
            ]
        )
    }

    func handleCommand(selector: Selector) -> Bool {
        switch selector {
        case #selector(cancelOperation(_:)):
            commandHandler?(.escape)
            return true
        case #selector(insertNewline(_:)), #selector(insertLineBreak(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                commandHandler?(.previous)
            } else {
                commandHandler?(.next)
            }
            return true
        default:
            return false
        }
    }
}

@MainActor
final class PaneSearchHUDButton: NSButton {
    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        setButtonType(.momentaryChange)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 22, height: 22)
    }

    override func performClick(_ sender: Any?) {
        guard isEnabled else {
            return
        }

        super.performClick(sender)
    }
}
