import AppKit
import QuartzCore

@MainActor
final class SidebarGlobalSearchRowView: NSView {
    private static let placeholder = "Search across panes"

    enum ControlKind {
        case previous
        case next
        case clear
    }

    static let preferredHeight: CGFloat = 40

    private enum Layout {
        static let inputHeight: CGFloat = 40
        static let inputInset = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        static let fieldLeading: CGFloat = 9
        static let itemSpacing: CGFloat = 6
        static let countWidth: CGFloat = 42
        static let buttonSize = CGSize(width: 22, height: 22)
    }

    private let inputContainer = NSView()
    private let queryField = PaneSearchTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let clearButton = PaneSearchHUDButton()
    private let previousButton = PaneSearchHUDButton()
    private let nextButton = PaneSearchHUDButton()
    private var queryFieldToCountConstraint: NSLayoutConstraint?
    private var queryFieldToPreviousConstraint: NSLayoutConstraint?
    private var countWidthConstraint: NSLayoutConstraint?
    private var clearWidthConstraint: NSLayoutConstraint?
    private var isProgrammaticFieldUpdate = false
    private var currentTheme = ZenttyTheme.fallback(for: nil)

    var onQueryChanged: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        appearance = NSAppearance(named: theme.sidebarGlassAppearance.nsAppearanceName)
        queryField.applySearchHUDTheme(
            textColor: theme.secondaryText.withAlphaComponent(0.96),
            placeholderColor: theme.tertiaryText.withAlphaComponent(0.72),
            placeholder: Self.placeholder
        )
        countLabel.textColor = theme.tertiaryText
        clearButton.contentTintColor = theme.tertiaryText.withAlphaComponent(0.72)
        previousButton.contentTintColor = theme.tertiaryText.withAlphaComponent(0.82)
        nextButton.contentTintColor = theme.tertiaryText.withAlphaComponent(0.82)

        let inputBackground = theme.sidebarBackground
            .mixed(towards: theme.primaryText, amount: theme.sidebarBackground.isDarkThemeColor ? 0.10 : 0.12)
            .withAlphaComponent(min(1, theme.sidebarBackground.alphaComponent + 0.08))
        let border = theme.primaryText.withAlphaComponent(theme.sidebarBackground.isDarkThemeColor ? 0.10 : 0.12)

        performThemeAnimation(animated: animated) {
            self.inputContainer.layer?.backgroundColor = inputBackground.cgColor
            self.inputContainer.layer?.borderColor = border.cgColor
        }
    }

    func apply(search: GlobalSearchState) {
        if queryField.stringValue != search.needle {
            isProgrammaticFieldUpdate = true
            queryField.stringValue = search.needle
            isProgrammaticFieldUpdate = false
        }
        countLabel.stringValue = countText(for: search)
        updateAccessoryLayout(hasQuery: !search.needle.isEmpty)
        previousButton.isEnabled = search.total > 0
        nextButton.isEnabled = search.total > 0
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

    var isFieldFocused: Bool {
        queryField.currentEditor() != nil
    }

    var queryTextForTesting: String {
        queryField.stringValue
    }

    var placeholderForTesting: String {
        queryField.placeholderString ?? queryField.placeholderAttributedString?.string ?? ""
    }

    var inputFrameForTesting: CGRect {
        convert(inputContainer.bounds, from: inputContainer)
    }

    var queryFieldTrailingGapToPreviousButtonForTesting: CGFloat {
        layoutSubtreeIfNeeded()
        let queryFrame = queryField.convert(queryField.bounds, to: self)
        let previousFrame = previousButton.convert(previousButton.bounds, to: self)
        return previousFrame.minX - queryFrame.maxX
    }

    var activeQueryTrailingConstraintCountForTesting: Int {
        [queryFieldToCountConstraint, queryFieldToPreviousConstraint].compactMap { $0 }
            .filter { $0.isActive }
            .count
    }

    var activeQueryTrailingConstraintTargetForTesting: String {
        var activeTargets: [String] = []
        if queryFieldToCountConstraint?.isActive == true {
            activeTargets.append("count")
        }
        if queryFieldToPreviousConstraint?.isActive == true {
            activeTargets.append("previous")
        }

        return activeTargets.joined(separator: "+")
    }

    func performClearForTesting() {
        handleClearButton()
    }

    func performNextCommandForTesting() {
        handleFieldCommand(.next)
    }

    func controlPointInWindowForTesting(_ control: ControlKind) -> NSPoint? {
        layoutSubtreeIfNeeded()
        let target: NSView = switch control {
        case .previous:
            previousButton
        case .next:
            nextButton
        case .clear:
            clearButton
        }
        guard !isHidden, !target.isHidden else {
            return nil
        }
        return target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        inputContainer.translatesAutoresizingMaskIntoConstraints = false
        inputContainer.wantsLayer = true
        inputContainer.layer?.cornerRadius = 12
        inputContainer.layer?.cornerCurve = .continuous
        inputContainer.layer?.borderWidth = 1
        inputContainer.layer?.masksToBounds = true

        queryField.placeholderString = Self.placeholder
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

        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear Global Find")
        clearButton.target = self
        clearButton.action = #selector(handleClearButton)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        previousButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Find Previous")
        previousButton.target = self
        previousButton.action = #selector(handlePreviousButton)
        previousButton.translatesAutoresizingMaskIntoConstraints = false

        nextButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Find Next")
        nextButton.target = self
        nextButton.action = #selector(handleNextButton)
        nextButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(inputContainer)
        inputContainer.addSubview(queryField)
        inputContainer.addSubview(countLabel)
        inputContainer.addSubview(clearButton)
        inputContainer.addSubview(previousButton)
        inputContainer.addSubview(nextButton)

        let inputTop = inputContainer.topAnchor.constraint(equalTo: topAnchor, constant: Layout.inputInset.top)
        let inputBottom = inputContainer.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: -Layout.inputInset.bottom
        )
        let inputHeight = inputContainer.heightAnchor.constraint(equalToConstant: Layout.inputHeight)
        inputTop.priority = .defaultHigh
        inputBottom.priority = .defaultHigh
        inputHeight.priority = .defaultHigh
        let queryFieldToCountConstraint = queryField.trailingAnchor.constraint(
            equalTo: countLabel.leadingAnchor,
            constant: -Layout.itemSpacing
        )
        let queryFieldToPreviousConstraint = queryField.trailingAnchor.constraint(
            equalTo: previousButton.leadingAnchor,
            constant: -Layout.itemSpacing
        )
        queryFieldToPreviousConstraint.isActive = false
        let countWidthConstraint = countLabel.widthAnchor.constraint(equalToConstant: Layout.countWidth)
        let clearWidthConstraint = clearButton.widthAnchor.constraint(equalToConstant: Layout.buttonSize.width)
        countLabel.isHidden = true
        clearButton.isHidden = true
        countWidthConstraint.constant = 0
        clearWidthConstraint.constant = 0
        self.queryFieldToCountConstraint = queryFieldToCountConstraint
        self.queryFieldToPreviousConstraint = queryFieldToPreviousConstraint
        self.countWidthConstraint = countWidthConstraint
        self.clearWidthConstraint = clearWidthConstraint

        NSLayoutConstraint.activate([
            inputTop,
            inputContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            inputBottom,
            inputHeight,

            queryField.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: Layout.fieldLeading),
            queryField.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            queryFieldToPreviousConstraint,

            countLabel.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -Layout.itemSpacing),
            countWidthConstraint,

            clearButton.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: previousButton.leadingAnchor, constant: -Layout.itemSpacing),
            clearWidthConstraint,
            clearButton.heightAnchor.constraint(equalToConstant: Layout.buttonSize.height),

            previousButton.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            previousButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -2),
            previousButton.widthAnchor.constraint(equalToConstant: Layout.buttonSize.width),
            previousButton.heightAnchor.constraint(equalToConstant: Layout.buttonSize.height),

            nextButton.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -Layout.inputInset.right),
            nextButton.widthAnchor.constraint(equalToConstant: Layout.buttonSize.width),
            nextButton.heightAnchor.constraint(equalToConstant: Layout.buttonSize.height),
        ])

        apply(theme: currentTheme, animated: false)
        apply(search: GlobalSearchState())
    }

    private func updateAccessoryLayout(hasQuery: Bool) {
        if hasQuery {
            queryFieldToPreviousConstraint?.isActive = false
            countWidthConstraint?.constant = Layout.countWidth
            clearWidthConstraint?.constant = Layout.buttonSize.width
            countLabel.isHidden = false
            clearButton.isHidden = false
            queryFieldToCountConstraint?.isActive = true
        } else {
            queryFieldToCountConstraint?.isActive = false
            countWidthConstraint?.constant = 0
            clearWidthConstraint?.constant = 0
            countLabel.isHidden = true
            clearButton.isHidden = true
            queryFieldToPreviousConstraint?.isActive = true
        }
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
            onNext?()
        case .previous:
            onPrevious?()
        case .escape:
            onClose?()
        }
    }

    @objc
    private func handleClearButton() {
        isProgrammaticFieldUpdate = true
        queryField.stringValue = ""
        isProgrammaticFieldUpdate = false
        updateAccessoryLayout(hasQuery: false)
        onQueryChanged?("")
        focusField(selectAll: false)
    }

    @objc
    private func handlePreviousButton() {
        onPrevious?()
    }

    @objc
    private func handleNextButton() {
        onNext?()
    }
}

extension SidebarGlobalSearchRowView: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ notification: Notification) {
        onFocusChanged?(true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        onFocusChanged?(false)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isProgrammaticFieldUpdate else {
            return
        }
        updateAccessoryLayout(hasQuery: !queryField.stringValue.isEmpty)
        onQueryChanged?(queryField.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        queryField.handleCommand(selector: commandSelector)
    }
}
