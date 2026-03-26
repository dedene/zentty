import AppKit

@MainActor
final class OpenWithPopoverContentViewController: NSViewController {
    private let contentView = OpenWithPopoverContentView()
    var onSelectTarget: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onDismissRequested: (() -> Void)?

    override func loadView() {
        view = contentView
        contentView.onSelectTarget = { [weak self] stableID in
            self?.onSelectTarget?(stableID)
        }
        contentView.onOpenSettings = { [weak self] in
            self?.onOpenSettings?()
        }
        contentView.onDismissRequested = { [weak self] in
            self?.onDismissRequested?()
        }
    }

    func render(theme: ZenttyTheme, items: [OpenWithPopoverItem]) {
        contentView.render(theme: theme, items: items)
    }

    func focusList() {
        view.window?.makeFirstResponder(contentView)
    }

    func simulateHoverRowForTesting(stableID: String) {
        contentView.simulateHoverRowForTesting(stableID: stableID)
    }

    func simulateExitRowForTesting(stableID: String) {
        contentView.simulateExitRowForTesting(stableID: stableID)
    }

    func simulateHoverSettingsForTesting() {
        contentView.simulateHoverSettingsForTesting()
    }

    func performSettingsActionForTesting() {
        contentView.performSettingsActionForTesting()
    }

    func dismissWithEscapeForTesting() {
        contentView.dismissWithEscapeForTesting()
    }

    func moveSelectionDownForTesting() {
        contentView.moveSelectionDownForTesting()
    }

    func activateSelectionForTesting() {
        contentView.activateSelectionForTesting()
    }

    var preferredPopoverSize: NSSize {
        contentView.preferredPopoverSize
    }

    var selectedStableIDForTesting: String? {
        contentView.selectedStableIDForTesting
    }

    var enabledStableIDsForTesting: [String] {
        contentView.enabledStableIDsForTesting
    }

    var disabledStableIDsForTesting: [String] {
        contentView.disabledStableIDsForTesting
    }

    var highlightedStableIDForTesting: String? {
        contentView.highlightedStableIDForTesting
    }

    var settingsBackgroundTokenForTesting: String {
        contentView.settingsBackgroundTokenForTesting
    }

    var settingsBorderTokenForTesting: String {
        contentView.settingsBorderTokenForTesting
    }

    func rowBackgroundTokenForTesting(stableID: String) -> String {
        contentView.rowBackgroundTokenForTesting(stableID: stableID)
    }

    func rowBorderTokenForTesting(stableID: String) -> String {
        contentView.rowBorderTokenForTesting(stableID: stableID)
    }
}

@MainActor
private final class OpenWithPopoverContentView: NSView {
    private enum Layout {
        static let width: CGFloat = 208
        static let surfaceInset: CGFloat = 6
        static let rowHeight: CGFloat = 30
        static let footerHeight: CGFloat = 30
        static let interRowSpacing: CGFloat = 2
        static let sectionSpacing: CGFloat = 6
    }

    private let surfaceView = GlassSurfaceView(style: .openWithPopover)
    private let stackView = NSStackView()
    private let footerSeparatorView = NSView()
    private let footerButton = OpenWithPopoverFooterButton()
    private var rowButtons: [OpenWithPopoverRowButton] = []
    private var currentItems: [OpenWithPopoverItem] = []
    private var highlightedIndex: Int?
    private var currentTheme = ZenttyTheme.fallback(for: nil)

    var onSelectTarget: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onDismissRequested: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53:
            onDismissRequested?()
        case 125:
            moveHighlight(delta: 1)
        case 126:
            moveHighlight(delta: -1)
        case 36, 49:
            activateHighlightedItem()
        default:
            super.keyDown(with: event)
        }
    }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(surfaceView)
        surfaceView.addSubview(stackView)
        surfaceView.addSubview(footerSeparatorView)
        surfaceView.addSubview(footerButton)

        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        footerSeparatorView.translatesAutoresizingMaskIntoConstraints = false
        footerSeparatorView.wantsLayer = true

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = Layout.interRowSpacing

        footerButton.onPress = { [weak self] in
            self?.onOpenSettings?()
        }

        NSLayoutConstraint.activate([
            surfaceView.topAnchor.constraint(equalTo: topAnchor, constant: Layout.surfaceInset),
            surfaceView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.surfaceInset),
            surfaceView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.surfaceInset),
            surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.surfaceInset),

            stackView.topAnchor.constraint(equalTo: surfaceView.topAnchor, constant: Layout.surfaceInset),
            stackView.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor, constant: Layout.surfaceInset),
            stackView.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor, constant: -Layout.surfaceInset),

            footerSeparatorView.topAnchor.constraint(equalTo: stackView.bottomAnchor, constant: Layout.sectionSpacing),
            footerSeparatorView.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor, constant: Layout.surfaceInset),
            footerSeparatorView.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor, constant: -Layout.surfaceInset),
            footerSeparatorView.heightAnchor.constraint(equalToConstant: 1),

            footerButton.topAnchor.constraint(equalTo: footerSeparatorView.bottomAnchor, constant: Layout.sectionSpacing),
            footerButton.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor, constant: Layout.surfaceInset),
            footerButton.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor, constant: -Layout.surfaceInset),
            footerButton.heightAnchor.constraint(equalToConstant: Layout.footerHeight),
            footerButton.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor, constant: -Layout.surfaceInset),
        ])
    }

    func render(theme: ZenttyTheme, items: [OpenWithPopoverItem]) {
        currentTheme = theme
        currentItems = items
        surfaceView.apply(theme: theme, animated: false)
        footerSeparatorView.layer?.backgroundColor = theme.openWithPopoverFooterSeparator.cgColor
        footerButton.apply(theme: theme, animated: false)

        rowButtons.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        rowButtons = items.enumerated().map { index, item in
            let button = OpenWithPopoverRowButton(item: item)
            button.onPress = { [weak self] stableID in
                self?.onSelectTarget?(stableID)
            }
            button.onHover = { [weak self] in
                self?.highlightedIndex = index
                self?.applyHighlightState()
            }
            button.onHoverEnded = { [weak self] in
                guard let self, self.highlightedIndex == index else {
                    return
                }

                self.highlightedIndex = nil
                self.applyHighlightState()
            }
            button.apply(theme: theme, animated: false)
            return button
        }

        rowButtons.forEach { button in
            stackView.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: Layout.rowHeight).isActive = true
        }

        highlightedIndex = nil
        applyHighlightState()
        invalidateIntrinsicContentSize()
    }

    private func moveHighlight(delta: Int) {
        let enabledIndices = currentItems.enumerated().compactMap { $0.element.isEnabled ? $0.offset : nil }
        guard !enabledIndices.isEmpty else {
            return
        }

        let current = highlightedIndex.flatMap { enabledIndices.firstIndex(of: $0) }
        let next: Int
        if let current {
            next = max(0, min(enabledIndices.count - 1, current + delta))
        } else if delta >= 0 {
            next = 0
        } else {
            next = enabledIndices.count - 1
        }

        highlightedIndex = enabledIndices[next]
        applyHighlightState()
    }

    private func activateHighlightedItem() {
        guard
            let highlightedIndex,
            currentItems.indices.contains(highlightedIndex),
            currentItems[highlightedIndex].isEnabled
        else {
            return
        }

        onSelectTarget?(currentItems[highlightedIndex].stableID)
    }

    private func applyHighlightState() {
        for (index, button) in rowButtons.enumerated() {
            button.isKeyboardHighlighted = index == highlightedIndex
            button.apply(theme: currentTheme, animated: true)
        }
    }

    func performSettingsActionForTesting() {
        onOpenSettings?()
    }

    func dismissWithEscapeForTesting() {
        onDismissRequested?()
    }

    func moveSelectionDownForTesting() {
        moveHighlight(delta: 1)
    }

    func activateSelectionForTesting() {
        activateHighlightedItem()
    }

    var preferredPopoverSize: NSSize {
        let rowsHeight = CGFloat(max(rowButtons.count, 1)) * Layout.rowHeight
        let rowsSpacing = CGFloat(max(rowButtons.count - 1, 0)) * Layout.interRowSpacing
        let chromeHeight = (Layout.surfaceInset * 4) + Layout.sectionSpacing + 1 + Layout.footerHeight
        return NSSize(width: Layout.width, height: rowsHeight + rowsSpacing + chromeHeight)
    }

    var selectedStableIDForTesting: String? {
        currentItems.first(where: { $0.isSelected })?.stableID
    }

    var enabledStableIDsForTesting: [String] {
        currentItems.filter { $0.isEnabled }.map(\.stableID)
    }

    var disabledStableIDsForTesting: [String] {
        currentItems.filter { !$0.isEnabled }.map(\.stableID)
    }

    var highlightedStableIDForTesting: String? {
        guard let highlightedIndex, currentItems.indices.contains(highlightedIndex) else {
            return nil
        }

        return currentItems[highlightedIndex].stableID
    }

    var settingsBackgroundTokenForTesting: String {
        footerButton.backgroundTokenForTesting
    }

    var settingsBorderTokenForTesting: String {
        footerButton.borderTokenForTesting
    }

    func simulateHoverRowForTesting(stableID: String) {
        guard
            let index = currentItems.firstIndex(where: { $0.stableID == stableID }),
            rowButtons.indices.contains(index)
        else {
            return
        }

        rowButtons[index].setHoveredForTesting(true)
    }

    func simulateExitRowForTesting(stableID: String) {
        guard
            let index = currentItems.firstIndex(where: { $0.stableID == stableID }),
            rowButtons.indices.contains(index)
        else {
            return
        }

        rowButtons[index].setHoveredForTesting(false)
    }

    func simulateHoverSettingsForTesting() {
        footerButton.setHoveredForTesting(true)
    }

    func rowBackgroundTokenForTesting(stableID: String) -> String {
        guard
            let index = currentItems.firstIndex(where: { $0.stableID == stableID }),
            rowButtons.indices.contains(index)
        else {
            return ""
        }

        return rowButtons[index].backgroundTokenForTesting
    }

    func rowBorderTokenForTesting(stableID: String) -> String {
        guard
            let index = currentItems.firstIndex(where: { $0.stableID == stableID }),
            rowButtons.indices.contains(index)
        else {
            return ""
        }

        return rowButtons[index].borderTokenForTesting
    }
}
