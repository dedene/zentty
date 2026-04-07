import AppKit

@MainActor
protocol WindowSearchHUDViewDelegate: AnyObject {
    func windowSearchHUDView(_ hudView: WindowSearchHUDView, didChangeQuery query: String)
    func windowSearchHUDViewDidRequestNext(_ hudView: WindowSearchHUDView)
    func windowSearchHUDViewDidRequestPrevious(_ hudView: WindowSearchHUDView)
    func windowSearchHUDViewDidRequestHide(_ hudView: WindowSearchHUDView)
    func windowSearchHUDViewDidRequestClose(_ hudView: WindowSearchHUDView)
}

@MainActor
final class WindowSearchHUDView: NSView {
    enum ButtonKind {
        case previous
        case next
        case close
    }

    private enum Layout {
        static let size = CGSize(width: 336, height: 42)
        static let contentInset = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        static let interItemSpacing: CGFloat = 8
        static let buttonSpacing: CGFloat = 4
        static let countWidth: CGFloat = 42
        static let buttonSize = CGSize(width: 22, height: 22)
    }

    private let countLabel = NSTextField(labelWithString: "-/0")
    private let queryField = PaneSearchTextField()
    private let previousButton = PaneSearchHUDButton()
    private let nextButton = PaneSearchHUDButton()
    private let closeButton = PaneSearchHUDButton()
    private var isProgrammaticFieldUpdate = false

    weak var delegate: (any WindowSearchHUDViewDelegate)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(search: GlobalSearchState) {
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

    var queryFieldForTesting: NSTextField {
        queryField
    }

    func buttonPointInWindowForTesting(_ button: ButtonKind) -> NSPoint? {
        guard isHidden == false else {
            return nil
        }

        let targetButton: NSButton = switch button {
        case .previous:
            previousButton
        case .next:
            nextButton
        case .close:
            closeButton
        }

        return targetButton.convert(
            NSPoint(x: targetButton.bounds.midX, y: targetButton.bounds.midY),
            to: nil
        )
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Layout.size.width, height: Layout.size.height)
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        invalidateInteractiveCursorRects()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateInteractiveCursorRects()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.96).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.08).cgColor

        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = NSColor(white: 0.74, alpha: 1)
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        queryField.placeholderString = "Global Find"
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

        previousButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Find Previous")
        previousButton.contentTintColor = NSColor(white: 0.76, alpha: 1)
        previousButton.target = self
        previousButton.action = #selector(handlePreviousButton)
        previousButton.translatesAutoresizingMaskIntoConstraints = false

        nextButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Find Next")
        nextButton.contentTintColor = NSColor(white: 0.76, alpha: 1)
        nextButton.target = self
        nextButton.action = #selector(handleNextButton)
        nextButton.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Global Find")
        closeButton.contentTintColor = NSColor(white: 0.76, alpha: 1)
        closeButton.target = self
        closeButton.action = #selector(handleCloseButton)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(queryField)
        addSubview(countLabel)
        addSubview(previousButton)
        addSubview(nextButton)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Layout.size.width),
            heightAnchor.constraint(equalToConstant: Layout.size.height),

            queryField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.contentInset.left),
            queryField.centerYAnchor.constraint(equalTo: centerYAnchor),
            queryField.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -Layout.interItemSpacing),

            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: previousButton.leadingAnchor, constant: -Layout.interItemSpacing),
            countLabel.widthAnchor.constraint(equalToConstant: Layout.countWidth),

            previousButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            previousButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -Layout.buttonSpacing),
            previousButton.widthAnchor.constraint(equalToConstant: Layout.buttonSize.width),
            previousButton.heightAnchor.constraint(equalToConstant: Layout.buttonSize.height),

            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -Layout.buttonSpacing),
            nextButton.widthAnchor.constraint(equalToConstant: Layout.buttonSize.width),
            nextButton.heightAnchor.constraint(equalToConstant: Layout.buttonSize.height),

            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.contentInset.right),
            closeButton.widthAnchor.constraint(equalToConstant: Layout.buttonSize.width),
            closeButton.heightAnchor.constraint(equalToConstant: Layout.buttonSize.height),
        ])

        isHidden = true
    }

    private func countText(for search: GlobalSearchState) -> String {
        let totalText = search.total >= 0 ? String(search.total) : "?"
        if search.selected >= 0 {
            return "\(search.selected + 1)/\(totalText)"
        }

        return "-/\(totalText)"
    }

    private func handleFieldCommand(_ command: PaneSearchTextField.Command) {
        switch command {
        case .next:
            delegate?.windowSearchHUDViewDidRequestNext(self)
        case .previous:
            delegate?.windowSearchHUDViewDidRequestPrevious(self)
        case .escape:
            if queryField.stringValue.isEmpty {
                delegate?.windowSearchHUDViewDidRequestClose(self)
            } else {
                delegate?.windowSearchHUDViewDidRequestHide(self)
            }
        }
    }

    @objc
    private func handlePreviousButton() {
        delegate?.windowSearchHUDViewDidRequestPrevious(self)
    }

    @objc
    private func handleNextButton() {
        delegate?.windowSearchHUDViewDidRequestNext(self)
    }

    @objc
    private func handleCloseButton() {
        delegate?.windowSearchHUDViewDidRequestClose(self)
    }

    private func invalidateInteractiveCursorRects() {
        guard let window else {
            return
        }

        for view in [self, queryField, previousButton, nextButton, closeButton] {
            window.invalidateCursorRects(for: view)
        }
    }
}

extension WindowSearchHUDView: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard !isProgrammaticFieldUpdate else {
            return
        }

        delegate?.windowSearchHUDView(self, didChangeQuery: queryField.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        queryField.handleCommand(selector: commandSelector)
    }
}
