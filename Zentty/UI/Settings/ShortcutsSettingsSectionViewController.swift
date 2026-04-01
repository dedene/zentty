import AppKit
import Carbon.HIToolbox

@MainActor
final class ShortcutsSettingsSectionViewController: SettingsScrollableSectionViewController, SettingsAppearanceUpdating {
    private enum Layout {
        static let contentSpacing: CGFloat = 16
        static let shellHeight: CGFloat = 430
        static let browserWidth: CGFloat = 360
        static let shellInset: CGFloat = 2
        static let browserBackgroundCornerRadius: CGFloat = 8
        static let topInset: CGFloat = 22
        static let bottomInset: CGFloat = 28
        static let shellSpacing: CGFloat = 24
        static let searchHeight: CGFloat = 32
        static let headerActionSize: CGFloat = 30
        static let rowHeight: CGFloat = 34
        static let sectionHeaderHeight: CGFloat = 24
        static let categoryHorizontalInset: CGFloat = 10
        static let rowHorizontalInset: CGFloat = 10
        static let detailSpacing: CGFloat = 14
        static let detailTitleFontSize: CGFloat = 26
        static let shortcutControlHeight: CGFloat = 52
        static let shortcutControlInset: CGFloat = 12
        static let conflictSpacing: CGFloat = 6
        static let previewHeight: CGFloat = 182
        static let headerRowHeight: CGFloat = max(searchHeight, headerActionSize)
        static let preferredViewportHeight: CGFloat =
            topInset + headerRowHeight + contentSpacing + shellHeight + bottomInset
    }

    private enum ShortcutIssue: Equatable {
        case message(String)
        case conflict(AppCommandID)
    }

    private enum BrowserItem: Equatable {
        case category(ShortcutCategory)
        case command(AppCommandID)

        var commandID: AppCommandID? {
            guard case let .command(commandID) = self else {
                return nil
            }
            return commandID
        }
    }

    private let configStore: AppConfigStore
    private let searchField = NSSearchField()
    private let overflowButton = NSButton()
    private let overflowMenu = NSMenu()
    private let browserCardView = SettingsCardView()
    private let browserScrollView = NSScrollView()
    private let browserTableView = ShortcutsBrowserTableView()
    private let detailContainerView = NSView()
    private let commandTitleLabel = NSTextField(labelWithString: "")
    private let categoryLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let shortcutControlView = NSView()
    private let shortcutFieldButton = NSButton(title: "", target: nil, action: nil)
    private let clearButton = NSButton()
    private let errorLabel = NSTextField(labelWithString: "")
    private let conflictContainerView = NSStackView()
    private let conflictLabel = NSTextField(labelWithString: "This shortcut conflicts with another shortcut:")
    private let conflictTargetButton = NSButton(title: "", target: nil, action: nil)
    private let keyboardPreviewView = KeyboardShortcutPreviewView()
    private let emptyStateLabel = NSTextField(labelWithString: "No shortcuts match your search.")

    private var currentShortcuts: AppConfig.Shortcuts = .default
    private var shortcutManager: ShortcutManager
    private let keyboardPreviewResolver = KeyboardLayoutPreviewResolver()
    private let keyboardInputSourceCenter = DistributedNotificationCenter.default()
    private var recordingCommandID: AppCommandID?
    private var keyMonitor: Any?
    private var isKeyboardInputSourceObserverInstalled = false
    private var issueByCommandID: [AppCommandID: ShortcutIssue] = [:]
    private var searchQuery = ""
    private var browserItems: [BrowserItem] = []
    private var selectedCommandID: AppCommandID?

    init(configStore: AppConfigStore) {
        self.configStore = configStore
        self.shortcutManager = ShortcutManager(shortcuts: configStore.current.shortcuts)
        self.selectedCommandID = AppCommandRegistry.definitions.first?.id
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func assembleContent(in contentView: NSView) {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = Layout.contentSpacing
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        configureSearchField()
        configureOverflowButton()

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        headerRow.addArrangedSubview(searchField)
        searchField.heightAnchor.constraint(equalToConstant: Layout.searchHeight).isActive = true

        headerRow.addArrangedSubview(overflowButton)
        overflowButton.widthAnchor.constraint(equalToConstant: Layout.headerActionSize).isActive = true
        overflowButton.heightAnchor.constraint(equalToConstant: Layout.headerActionSize).isActive = true

        let shellView = makeShellView()
        stackView.addArrangedSubview(shellView)
        shellView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        shellView.heightAnchor.constraint(equalToConstant: Layout.shellHeight).isActive = true

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])

        rebuildBrowserItems(preserveSelection: false)
        browserTableView.reloadData()
        syncSelectionToTableView()
        refreshDetailPane()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installKeyMonitorIfNeeded()
        installKeyboardInputSourceObserverIfNeeded()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        removeKeyMonitor()
        removeKeyboardInputSourceObserver()
    }

    override func prepareForPresentation() {
        super.prepareForPresentation()
        updateAppearanceColors()
        rebuildBrowserItems(preserveSelection: true)
        browserTableView.reloadData()
        syncSelectionToTableView()
        refreshDetailPane()
    }

    override func preferredViewportHeight(for width: CGFloat) -> CGFloat {
        Layout.preferredViewportHeight
    }

    var visibleCategoryTitles: [String] {
        browserItems.compactMap { item in
            guard case let .category(category) = item else {
                return nil
            }
            return category.title
        }
    }

    var visibleCommandTitles: [String] {
        browserItems.compactMap { item in
            guard case let .command(commandID) = item else {
                return nil
            }
            return AppCommandRegistry.definition(for: commandID).title
        }
    }

    var selectedCommandTitleForTesting: String? {
        selectedCommandID.map { AppCommandRegistry.definition(for: $0).title }
    }

    var selectedCommandDescriptionForTesting: String? {
        selectedCommandID.map { AppCommandRegistry.definition(for: $0).detailDescription }
    }

    var selectedCommandDefaultShortcutForTesting: String? {
        defaultShortcutValueForCurrentSelection()
    }

    var browserHasVerticalScrollerForTesting: Bool {
        browserScrollView.hasVerticalScroller
    }

    var isSearchFieldFullyVisibleForTesting: Bool {
        guard let documentView = scrollView.documentView else {
            return false
        }

        view.layoutSubtreeIfNeeded()
        let searchFieldRect = searchField.convert(searchField.bounds, to: documentView)
        return scrollView.contentView.documentVisibleRect.contains(searchFieldRect)
    }

    var isFirstCategoryHeaderFullyVisibleForTesting: Bool {
        guard let categoryRow = browserItems.firstIndex(where: {
            if case .category = $0 {
                return true
            }
            return false
        }) else {
            return false
        }

        browserTableView.layoutSubtreeIfNeeded()
        let rowRect = browserTableView.rect(ofRow: categoryRow)
        return browserTableView.visibleRect.contains(rowRect)
    }

    var isSelectedCommandFullyVisibleForTesting: Bool {
        guard let selectedCommandID,
              let row = browserItems.firstIndex(where: { $0.commandID == selectedCommandID }) else {
            return false
        }

        browserTableView.layoutSubtreeIfNeeded()
        let rowRect = browserTableView.rect(ofRow: row)
        return browserTableView.visibleRect.contains(rowRect)
    }

    var selectedRowUsesEmphasizedTextColorForTesting: Bool {
        guard let selectedCommandID,
              let row = browserItems.firstIndex(where: { $0.commandID == selectedCommandID }) else {
            return false
        }

        browserTableView.layoutSubtreeIfNeeded()
        guard let cell = browserTableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ShortcutsBrowserCommandCellView else {
            return false
        }

        return cell.usesEmphasizedSelectionForTesting
    }

    func setSelectedRowEmphasizedForTesting(_ isEmphasized: Bool) {
        guard let selectedCommandID,
              let row = browserItems.firstIndex(where: { $0.commandID == selectedCommandID }),
              let rowView = browserTableView.rowView(atRow: row, makeIfNecessary: true) else {
            return
        }

        rowView.isEmphasized = isEmphasized
        rowView.needsDisplay = true
        rowView.displayIfNeeded()
        browserTableView.layoutSubtreeIfNeeded()
    }

    var usesFixedBrowserColumnForTesting: Bool {
        true
    }

    var shortcutEditorUsesFullWidthLayoutForTesting: Bool {
        shortcutControlView.superview != nil
    }

    var showsInlineClearAffordanceForTesting: Bool {
        clearButton.superview === shortcutControlView
    }

    var showsPerCommandRestoreActionForTesting: Bool {
        false
    }

    var showsResetAllShortcutsActionForTesting: Bool {
        overflowMenu.items.contains { $0.title == "Reset All Shortcuts" }
    }

    var conflictTargetTitleForTesting: String? {
        guard let selectedCommandID,
              case let .conflict(conflictingCommandID) = issueByCommandID[selectedCommandID] else {
            return nil
        }

        return AppCommandRegistry.definition(for: conflictingCommandID).title
    }

    var showsKeyboardPreviewForTesting: Bool {
        keyboardPreviewView.superview != nil
    }

    var previewPrimaryHighlightedKeyCodeForTesting: UInt16? {
        keyboardPreviewView.model.primaryHighlightedKeyCode
    }

    var previewHighlightedModifierKeyCodesForTesting: Set<UInt16> {
        keyboardPreviewView.model.highlightedModifierKeyCodes
    }

    func applySearchForTesting(_ query: String) {
        searchField.stringValue = query
        updateSearchQuery(query)
    }

    func typeSearchTextForTesting(_ query: String) {
        searchField.stringValue = query
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
    }

    func handleAppearanceChange() {
        guard isViewLoaded else {
            return
        }

        updateAppearanceColors()
        refreshBrowserSelectionAppearance()
        refreshDetailPane()
    }

    func selectCommandForTesting(_ commandID: AppCommandID) {
        selectedCommandID = commandID
        syncSelectionToTableView()
        refreshDetailPane()
    }

    func displayString(for commandID: AppCommandID) -> String {
        formattedShortcutDisplay(shortcutManager.shortcut(for: commandID))
    }

    func attemptShortcutAssignmentForTesting(_ shortcut: KeyboardShortcut) {
        guard let selectedCommandID else {
            return
        }
        commit(shortcut: shortcut, for: selectedCommandID)
    }

    func activateConflictTargetForTesting() {
        handleConflictTargetClicked(nil)
    }

    func apply(shortcuts: AppConfig.Shortcuts) {
        currentShortcuts = shortcuts.normalized()
        shortcutManager = ShortcutManager(shortcuts: currentShortcuts)
        rebuildBrowserItems(preserveSelection: true)
        browserTableView.reloadData()
        syncSelectionToTableView()
        refreshDetailPane()
    }

    private func configureSearchField() {
        searchField.placeholderString = "Search shortcuts"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.controlSize = .large
    }

    private func configureOverflowButton() {
        overflowButton.bezelStyle = .texturedRounded
        overflowButton.controlSize = .regular
        overflowButton.image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: "More shortcut actions"
        )
        overflowButton.imagePosition = .imageOnly
        overflowButton.target = self
        overflowButton.action = #selector(handleOverflowButtonClicked(_:))

        overflowMenu.removeAllItems()
        let resetItem = NSMenuItem(
            title: "Reset All Shortcuts",
            action: #selector(handleResetAllShortcuts(_:)),
            keyEquivalent: ""
        )
        resetItem.target = self
        overflowMenu.addItem(resetItem)
    }

    private func makeShellView() -> NSView {
        let shellView = NSView()
        shellView.translatesAutoresizingMaskIntoConstraints = false

        browserCardView.translatesAutoresizingMaskIntoConstraints = false
        browserCardView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shellView.addSubview(browserCardView)

        configureBrowserTable()
        browserCardView.addSubview(browserScrollView)
        NSLayoutConstraint.activate([
            browserScrollView.topAnchor.constraint(equalTo: browserCardView.topAnchor, constant: Layout.shellInset),
            browserScrollView.leadingAnchor.constraint(equalTo: browserCardView.leadingAnchor, constant: Layout.shellInset),
            browserScrollView.trailingAnchor.constraint(equalTo: browserCardView.trailingAnchor, constant: -Layout.shellInset),
            browserScrollView.bottomAnchor.constraint(equalTo: browserCardView.bottomAnchor, constant: -Layout.shellInset),
        ])

        configureDetailPane()
        detailContainerView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shellView.addSubview(detailContainerView)

        let browserWidthConstraint = browserCardView.widthAnchor.constraint(equalToConstant: Layout.browserWidth)
        browserWidthConstraint.priority = .defaultHigh
        let shellSpacingConstraint = detailContainerView.leadingAnchor.constraint(
            equalTo: browserCardView.trailingAnchor,
            constant: Layout.shellSpacing
        )
        shellSpacingConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            browserCardView.topAnchor.constraint(equalTo: shellView.topAnchor),
            browserCardView.leadingAnchor.constraint(equalTo: shellView.leadingAnchor),
            browserCardView.bottomAnchor.constraint(equalTo: shellView.bottomAnchor),
            browserWidthConstraint,

            detailContainerView.topAnchor.constraint(equalTo: shellView.topAnchor),
            shellSpacingConstraint,
            detailContainerView.trailingAnchor.constraint(equalTo: shellView.trailingAnchor),
            detailContainerView.bottomAnchor.constraint(equalTo: shellView.bottomAnchor),
        ])

        return shellView
    }

    private func configureBrowserTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        browserTableView.addTableColumn(column)
        browserTableView.headerView = nil
        browserTableView.intercellSpacing = .zero
        browserTableView.rowSizeStyle = .custom
        browserTableView.focusRingType = .none
        browserTableView.selectionHighlightStyle = .regular
        browserTableView.backgroundColor = .clear
        browserTableView.usesAlternatingRowBackgroundColors = false
        browserTableView.delegate = self
        browserTableView.dataSource = self
        browserTableView.target = self
        browserTableView.action = #selector(handleTableAction(_:))
        browserTableView.commandActivationHandler = { [weak self] in
            self?.beginRecordingSelectedCommand()
        }
        browserTableView.translatesAutoresizingMaskIntoConstraints = false

        browserScrollView.borderType = .noBorder
        browserScrollView.drawsBackground = true
        browserScrollView.hasVerticalScroller = true
        browserScrollView.autohidesScrollers = true
        browserScrollView.documentView = browserTableView
        browserScrollView.automaticallyAdjustsContentInsets = false
        browserScrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        browserScrollView.translatesAutoresizingMaskIntoConstraints = false

        updateAppearanceColors()
    }

    private func configureDetailPane() {
        detailContainerView.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = Layout.detailSpacing
        stackView.translatesAutoresizingMaskIntoConstraints = false
        detailContainerView.addSubview(stackView)

        categoryLabel.font = .systemFont(ofSize: 11, weight: .medium)
        categoryLabel.textColor = .secondaryLabelColor
        categoryLabel.lineBreakMode = .byTruncatingTail
        categoryLabel.maximumNumberOfLines = 1
        stackView.addArrangedSubview(categoryLabel)

        commandTitleLabel.font = .systemFont(ofSize: Layout.detailTitleFontSize, weight: .semibold)
        commandTitleLabel.lineBreakMode = .byWordWrapping
        commandTitleLabel.maximumNumberOfLines = 2
        stackView.addArrangedSubview(commandTitleLabel)
        commandTitleLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        descriptionLabel.font = .systemFont(ofSize: 13, weight: .regular)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.maximumNumberOfLines = 0
        stackView.addArrangedSubview(descriptionLabel)
        descriptionLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        shortcutControlView.wantsLayer = true
        shortcutControlView.layer?.cornerRadius = 14
        shortcutControlView.layer?.cornerCurve = .continuous
        shortcutControlView.layer?.borderWidth = 1
        shortcutControlView.translatesAutoresizingMaskIntoConstraints = false

        shortcutFieldButton.bezelStyle = .regularSquare
        shortcutFieldButton.isBordered = false
        shortcutFieldButton.controlSize = .large
        shortcutFieldButton.target = self
        shortcutFieldButton.action = #selector(handleShortcutFieldClicked(_:))
        shortcutFieldButton.font = .monospacedSystemFont(ofSize: 20, weight: .semibold)
        shortcutFieldButton.translatesAutoresizingMaskIntoConstraints = false
        shortcutControlView.addSubview(shortcutFieldButton)

        clearButton.bezelStyle = .regularSquare
        clearButton.isBordered = false
        clearButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Clear shortcut"
        )
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(handleClearShortcut(_:))
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        shortcutControlView.addSubview(clearButton)

        stackView.addArrangedSubview(shortcutControlView)
        shortcutControlView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        shortcutControlView.heightAnchor.constraint(equalToConstant: Layout.shortcutControlHeight).isActive = true

        errorLabel.font = .systemFont(ofSize: 12, weight: .regular)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 0
        stackView.addArrangedSubview(errorLabel)
        errorLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        conflictContainerView.orientation = .vertical
        conflictContainerView.alignment = .leading
        conflictContainerView.spacing = Layout.conflictSpacing
        conflictContainerView.translatesAutoresizingMaskIntoConstraints = false

        conflictLabel.font = .systemFont(ofSize: 12, weight: .regular)
        conflictLabel.textColor = .secondaryLabelColor
        conflictLabel.lineBreakMode = .byWordWrapping
        conflictLabel.maximumNumberOfLines = 0
        conflictContainerView.addArrangedSubview(conflictLabel)

        conflictTargetButton.bezelStyle = .inline
        conflictTargetButton.isBordered = false
        conflictTargetButton.contentTintColor = .systemRed
        conflictTargetButton.font = .systemFont(ofSize: 13, weight: .medium)
        conflictTargetButton.target = self
        conflictTargetButton.action = #selector(handleConflictTargetClicked(_:))
        conflictContainerView.addArrangedSubview(conflictTargetButton)

        stackView.addArrangedSubview(conflictContainerView)
        conflictContainerView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        keyboardPreviewView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(keyboardPreviewView)
        keyboardPreviewView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        keyboardPreviewView.heightAnchor.constraint(equalToConstant: Layout.previewHeight).isActive = true

        emptyStateLabel.font = .systemFont(ofSize: 12, weight: .regular)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.isHidden = true
        stackView.addArrangedSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: detailContainerView.topAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: detailContainerView.leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: detailContainerView.trailingAnchor, constant: -8),

            shortcutFieldButton.topAnchor.constraint(equalTo: shortcutControlView.topAnchor),
            shortcutFieldButton.leadingAnchor.constraint(equalTo: shortcutControlView.leadingAnchor),
            shortcutFieldButton.trailingAnchor.constraint(equalTo: shortcutControlView.trailingAnchor),
            shortcutFieldButton.bottomAnchor.constraint(equalTo: shortcutControlView.bottomAnchor),

            clearButton.trailingAnchor.constraint(equalTo: shortcutControlView.trailingAnchor, constant: -Layout.shortcutControlInset),
            clearButton.centerYAnchor.constraint(equalTo: shortcutControlView.centerYAnchor),
        ])
    }

    private func rebuildBrowserItems(preserveSelection: Bool) {
        let previousSelection = preserveSelection ? selectedCommandID : nil
        let normalizedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalizedQuery.isEmpty {
            browserItems = ShortcutCategory.allCases.flatMap { category -> [BrowserItem] in
                let commands = AppCommandRegistry.commands(in: category)
                guard commands.isEmpty == false else {
                    return []
                }
                return [.category(category)] + commands.map { .command($0.id) }
            }
        } else {
            browserItems = AppCommandRegistry.definitions
                .filter { $0.searchText.contains(normalizedQuery) }
                .map { .command($0.id) }
        }

        let visibleCommandIDs = browserItems.compactMap(\.commandID)
        if let previousSelection, visibleCommandIDs.contains(previousSelection) {
            selectedCommandID = previousSelection
        } else {
            selectedCommandID = visibleCommandIDs.first
        }
    }

    private func syncSelectionToTableView() {
        guard let selectedCommandID else {
            browserTableView.deselectAll(nil)
            return
        }

        guard let row = browserItems.firstIndex(where: { $0.commandID == selectedCommandID }) else {
            browserTableView.deselectAll(nil)
            return
        }

        browserTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        browserTableView.layoutSubtreeIfNeeded()
        let anchorRow: Int
        if row > 0, case .category = browserItems[row - 1] {
            anchorRow = row - 1
        } else {
            anchorRow = row
        }
        browserTableView.scrollRowToVisible(anchorRow)
        refreshBrowserSelectionAppearance()
    }

    private func refreshBrowserSelectionAppearance() {
        guard browserTableView.numberOfRows > 0 else {
            return
        }

        let visibleRows = browserTableView.rows(in: browserTableView.visibleRect)
        if visibleRows.length > 0 {
            for row in visibleRows.location ..< NSMaxRange(visibleRows) {
                guard row >= 0, row < browserTableView.numberOfRows else {
                    continue
                }
                (browserTableView.rowView(atRow: row, makeIfNecessary: false) as? ShortcutsBrowserRowView)?
                    .refreshSelectionAppearance()
            }
        }

        guard let selectedCommandID,
              let row = browserItems.firstIndex(where: { $0.commandID == selectedCommandID }) else {
            return
        }

        (browserTableView.rowView(atRow: row, makeIfNecessary: true) as? ShortcutsBrowserRowView)?
            .refreshSelectionAppearance()
    }

    private func refreshDetailPane() {
        guard let selectedCommandID else {
            commandTitleLabel.stringValue = "No Shortcut Selected"
            categoryLabel.stringValue = ""
            descriptionLabel.stringValue = "Choose a command from the list to inspect or edit its shortcut."
            shortcutFieldButton.title = "Record Shortcut"
            shortcutFieldButton.attributedTitle = NSAttributedString(string: "Record Shortcut")
            shortcutFieldButton.isEnabled = false
            clearButton.isHidden = true
            clearButton.isEnabled = false
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
            conflictContainerView.isHidden = true
            keyboardPreviewView.model = keyboardPreviewResolver.resolve(shortcut: nil)
            emptyStateLabel.isHidden = browserItems.isEmpty == false
            return
        }

        let definition = AppCommandRegistry.definition(for: selectedCommandID)
        let effectiveShortcut = shortcutManager.shortcut(for: selectedCommandID)
        let isRecording = recordingCommandID == selectedCommandID

        categoryLabel.stringValue = definition.category.title
        commandTitleLabel.stringValue = definition.title
        descriptionLabel.stringValue = definition.detailDescription
        let shortcutDisplay = isRecording ? "Type Shortcut…" : formattedShortcutDisplay(effectiveShortcut)
        shortcutFieldButton.title = shortcutDisplay
        shortcutFieldButton.attributedTitle = formattedShortcutAttributedString(shortcutDisplay, isRecording: isRecording)
        shortcutFieldButton.isEnabled = true
        clearButton.isHidden = shortcutManager.isUnbound(selectedCommandID)
        clearButton.isEnabled = shortcutManager.isUnbound(selectedCommandID) == false
        keyboardPreviewView.model = keyboardPreviewResolver.resolve(shortcut: effectiveShortcut)

        switch issueByCommandID[selectedCommandID] {
        case let .message(message):
            errorLabel.stringValue = message
            errorLabel.isHidden = false
            conflictContainerView.isHidden = true
        case let .conflict(conflictingCommandID):
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
            conflictTargetButton.title = "\(AppCommandRegistry.definition(for: conflictingCommandID).title) ↗"
            conflictContainerView.isHidden = false
        case nil:
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
            conflictContainerView.isHidden = true
        }
        emptyStateLabel.isHidden = true
    }

    private func defaultShortcutValueForCurrentSelection() -> String? {
        nil
    }

    private func formattedShortcutDisplay(_ shortcut: KeyboardShortcut?) -> String {
        guard let shortcut else {
            return "Unassigned"
        }

        let modifierSymbols = diaModifierOrder
            .filter { shortcut.modifiers.contains($0) }
            .map { modifierSymbol(for: $0) }
            .joined()
        return modifierSymbols + diaDisplayToken(for: shortcut.key)
    }

    private func formattedShortcutAttributedString(_ string: String, isRecording: Bool) -> NSAttributedString {
        let color: NSColor = isRecording ? .controlAccentColor : .labelColor
        return NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: color,
                .kern: -0.2,
            ]
        )
    }

    private var diaModifierOrder: [KeyboardModifier] {
        [.control, .option, .shift, .command]
    }

    private func modifierSymbol(for modifier: KeyboardModifier) -> String {
        switch modifier {
        case .command:
            return "⌘"
        case .control:
            return "⌃"
        case .option:
            return "⌥"
        case .shift:
            return "⇧"
        }
    }

    private func diaDisplayToken(for key: KeyboardShortcutKey) -> String {
        switch key {
        case .character(let value):
            return value.uppercased()
        case .tab:
            return "⇥"
        case .leftArrow:
            return "←"
        case .rightArrow:
            return "→"
        case .upArrow:
            return "↑"
        case .downArrow:
            return "↓"
        }
    }

    private func updateAppearanceColors() {
        let isDarkMode = view.effectiveAppearance.bestMatch(from: [NSAppearance.Name.darkAqua, NSAppearance.Name.aqua]) == .darkAqua
        browserScrollView.backgroundColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.025)
            : NSColor.black.withAlphaComponent(0.035)
        shortcutControlView.layer?.backgroundColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.07).cgColor
            : NSColor.black.withAlphaComponent(0.04).cgColor
        shortcutControlView.layer?.borderColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.08).cgColor
            : NSColor.black.withAlphaComponent(0.08).cgColor
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else {
            return
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let recordingCommandID else {
                return event
            }

            guard self.view.window?.isKeyWindow == true else {
                return event
            }

            switch event.keyCode {
            case 53:
                self.issueByCommandID[recordingCommandID] = nil
                self.recordingCommandID = nil
                self.refreshVisibleState()
                return nil
            case 51, 117:
                self.clearShortcut(for: recordingCommandID)
                return nil
            default:
                break
            }

            guard let shortcut = KeyboardShortcut(event: event) else {
                return nil
            }

            self.commit(shortcut: shortcut, for: recordingCommandID)
            return nil
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else {
            return
        }

        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    private func installKeyboardInputSourceObserverIfNeeded() {
        guard isKeyboardInputSourceObserverInstalled == false else {
            return
        }

        keyboardInputSourceCenter.addObserver(
            self,
            selector: #selector(handleKeyboardInputSourceChanged(_:)),
            name: Notification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        isKeyboardInputSourceObserverInstalled = true
    }

    private func removeKeyboardInputSourceObserver() {
        guard isKeyboardInputSourceObserverInstalled else {
            return
        }

        keyboardInputSourceCenter.removeObserver(
            self,
            name: Notification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
        isKeyboardInputSourceObserverInstalled = false
    }

    private func beginRecordingSelectedCommand() {
        guard let selectedCommandID else {
            return
        }
        beginRecording(commandID: selectedCommandID)
    }

    private func beginRecording(commandID: AppCommandID) {
        selectedCommandID = commandID
        recordingCommandID = commandID
        issueByCommandID[commandID] = nil
        syncSelectionToTableView()
        refreshVisibleState()
    }

    private func commit(shortcut: KeyboardShortcut, for commandID: AppCommandID) {
        guard shortcut.isEligibleCommandBinding else {
            issueByCommandID[commandID] = .message("Shortcut must include Command, Control, or Option.")
            refreshVisibleState()
            return
        }

        if let conflict = shortcutManager.conflict(for: shortcut, assigningTo: commandID) {
            issueByCommandID[commandID] = .conflict(conflict.commandID)
            recordingCommandID = nil
            refreshVisibleState()
            return
        }

        issueByCommandID[commandID] = nil
        recordingCommandID = nil
        persistShortcut(shortcut, for: commandID)
    }

    private func clearShortcut(for commandID: AppCommandID) {
        recordingCommandID = nil
        issueByCommandID[commandID] = nil
        persistShortcut(nil, for: commandID)
    }

    private func persistShortcut(_ shortcut: KeyboardShortcut?, for commandID: AppCommandID) {
        try? configStore.update { config in
            config.shortcuts = config.shortcuts.updating(commandID: commandID, shortcut: shortcut)
        }
        apply(shortcuts: configStore.current.shortcuts)
    }

    private func resetAllShortcuts() {
        recordingCommandID = nil
        issueByCommandID.removeAll()
        try? configStore.update { config in
            config.shortcuts = .default
        }
        searchField.stringValue = ""
        searchQuery = ""
        apply(shortcuts: configStore.current.shortcuts)
    }

    private func jumpToCommand(_ commandID: AppCommandID) {
        if browserItems.contains(where: { $0.commandID == commandID }) == false {
            searchField.stringValue = ""
            searchQuery = ""
            rebuildBrowserItems(preserveSelection: false)
            browserTableView.reloadData()
        }

        selectedCommandID = commandID
        syncSelectionToTableView()
        refreshDetailPane()
    }

    private func updateSearchQuery(_ query: String) {
        searchQuery = query
        rebuildBrowserItems(preserveSelection: true)
        browserTableView.reloadData()
        syncSelectionToTableView()
        refreshDetailPane()
    }

    private func refreshVisibleState() {
        browserTableView.reloadData()
        syncSelectionToTableView()
        refreshDetailPane()
    }

    @objc
    private func handleTableAction(_ sender: Any?) {
        let row = browserTableView.clickedRow
        guard row >= 0, row < browserItems.count, let commandID = browserItems[row].commandID else {
            return
        }
        selectedCommandID = commandID
        refreshDetailPane()
    }

    @objc
    private func handleShortcutFieldClicked(_ sender: Any?) {
        beginRecordingSelectedCommand()
    }

    @objc
    private func handleClearShortcut(_ sender: Any?) {
        guard let selectedCommandID else {
            return
        }
        clearShortcut(for: selectedCommandID)
    }

    @objc
    private func handleOverflowButtonClicked(_ sender: NSButton) {
        let location = NSPoint(x: sender.bounds.midX, y: sender.bounds.minY - 4)
        overflowMenu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc
    private func handleResetAllShortcuts(_ sender: Any?) {
        resetAllShortcuts()
    }

    @objc
    private func handleConflictTargetClicked(_ sender: Any?) {
        guard let selectedCommandID else {
            return
        }
        guard case let .conflict(conflictingCommandID) = issueByCommandID[selectedCommandID] else {
            return
        }
        jumpToCommand(conflictingCommandID)
    }

    @objc
    private func handleKeyboardInputSourceChanged(_ notification: Notification) {
        refreshDetailPane()
    }
}

@MainActor
extension ShortcutsSettingsSectionViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        browserItems.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard row >= 0, row < browserItems.count else {
            return false
        }
        if case .category = browserItems[row] {
            return true
        }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row >= 0, row < browserItems.count else {
            return false
        }
        return browserItems[row].commandID != nil
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < browserItems.count else {
            return Layout.rowHeight
        }
        switch browserItems[row] {
        case .category:
            return Layout.sectionHeaderHeight
        case .command:
            return Layout.rowHeight
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = browserTableView.selectedRow
        guard row >= 0, row < browserItems.count, let commandID = browserItems[row].commandID else {
            return
        }
        selectedCommandID = commandID
        refreshDetailPane()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ShortcutsBrowserRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < browserItems.count else {
            return nil
        }

        switch browserItems[row] {
        case let .category(category):
            let identifier = NSUserInterfaceItemIdentifier("category")
            let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? ShortcutsBrowserCategoryCellView)
                ?? ShortcutsBrowserCategoryCellView()
            view.identifier = identifier
            view.configure(title: category.title)
            return view
        case let .command(commandID):
            let identifier = NSUserInterfaceItemIdentifier("command")
            let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? ShortcutsBrowserCommandCellView)
                ?? ShortcutsBrowserCommandCellView()
            view.identifier = identifier
            view.configure(
                title: AppCommandRegistry.definition(for: commandID).title,
                shortcut: displayString(for: commandID),
                isRecording: recordingCommandID == commandID
            )
            return view
        }
    }
}

@MainActor
extension ShortcutsSettingsSectionViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        updateSearchQuery(searchField.stringValue)
    }
}

@MainActor
private final class ShortcutsBrowserTableView: NSTableView {
    var commandActivationHandler: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 49:
            commandActivationHandler?()
        default:
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class ShortcutsBrowserRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            guard oldValue != isSelected else {
                return
            }
            refreshSelectionAppearance()
        }
    }

    override var isEmphasized: Bool {
        didSet {
            guard oldValue != isEmphasized else {
                return
            }
            refreshSelectionAppearance()
        }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        refreshSelectionAppearance()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // Suppress default group row background that reduces text contrast.
    }

    override func drawSelection(in dirtyRect: NSRect) {
        refreshSelectionAppearance()

        guard selectionHighlightStyle != .none else {
            return
        }

        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 6, yRadius: 6).fill()
    }

    func refreshSelectionAppearance() {
        let usesSelectedTextColor = isSelected && selectionHighlightStyle != .none
        refreshCommandCellAppearance(in: self, usesSelectedTextColor: usesSelectedTextColor)
    }

    private func refreshCommandCellAppearance(in view: NSView, usesSelectedTextColor: Bool) {
        if let commandCell = view as? ShortcutsBrowserCommandCellView {
            commandCell.setSelectedAppearance(usesSelectedTextColor)
        }

        view.subviews.forEach { refreshCommandCellAppearance(in: $0, usesSelectedTextColor: usesSelectedTextColor) }
    }
}

@MainActor
private final class ShortcutsBrowserCategoryCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        titleLabel.stringValue = title
    }
}

@MainActor
private final class ShortcutsBrowserCommandCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private var currentShortcut = ""
    private var isRecording = false
    private var usesSelectedAppearance = false
    private var observedWindow: NSWindow?

    var titleColorForTesting: NSColor? {
        titleLabel.textColor
    }

    var usesEmphasizedSelectionForTesting: Bool {
        usesSelectedAppearance
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        shortcutLabel.font = .systemFont(ofSize: 14, weight: .medium)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.alignment = .right
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcutLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -12),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowObservation()
        syncSelectionAppearanceFromRowView()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        syncSelectionAppearanceFromRowView()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        syncSelectionAppearanceFromRowView()
    }

    func configure(title: String, shortcut: String, isRecording: Bool) {
        titleLabel.stringValue = title
        currentShortcut = shortcut
        self.isRecording = isRecording
        syncSelectionAppearanceFromRowView()
    }

    func setSelectedAppearance(_ usesSelectedAppearance: Bool) {
        if self.usesSelectedAppearance != usesSelectedAppearance {
            self.usesSelectedAppearance = usesSelectedAppearance
        }
        updateAppearance()
    }

    private func updateAppearance() {
        titleLabel.textColor = usesSelectedAppearance ? .alternateSelectedControlTextColor : .labelColor
        shortcutLabel.attributedStringValue = NSAttributedString(
            string: isRecording ? "Type Shortcut…" : currentShortcut,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: shortcutColor(usesSelectedAppearance: usesSelectedAppearance),
                .kern: -0.15,
            ]
        )
    }

    private func syncSelectionAppearanceFromRowView() {
        let rowView = enclosingRowView()
        let usesSelectedAppearance = rowView?.isSelected == true && rowView?.selectionHighlightStyle != .none
        setSelectedAppearance(usesSelectedAppearance)
    }

    private func updateWindowObservation() {
        guard observedWindow !== window else {
            return
        }

        NotificationCenter.default.removeObserver(self)
        observedWindow = window

        guard let window else {
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowFocusChange),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowFocusChange),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @objc
    private func handleWindowFocusChange() {
        syncSelectionAppearanceFromRowView()
    }

    private func enclosingRowView() -> NSTableRowView? {
        var candidate = superview
        while let view = candidate {
            if let rowView = view as? NSTableRowView {
                return rowView
            }
            candidate = view.superview
        }
        return nil
    }

    private func shortcutColor(usesSelectedAppearance: Bool) -> NSColor {
        if isRecording {
            return usesSelectedAppearance ? .alternateSelectedControlTextColor : .controlAccentColor
        }
        return usesSelectedAppearance
            ? .alternateSelectedControlTextColor
            : .secondaryLabelColor
    }
}
