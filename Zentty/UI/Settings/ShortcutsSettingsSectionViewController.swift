import AppKit

@MainActor
final class ShortcutsSettingsSectionViewController: SettingsScrollableSectionViewController {
    private enum Layout {
        static let categorySpacing: CGFloat = 16
    }

    private let configStore: AppConfigStore
    private let categoryStackView = NSStackView()
    private var rowViewsByCommandID: [AppCommandID: ShortcutBindingRowView] = [:]
    private var currentShortcuts: AppConfig.Shortcuts = .default
    private var shortcutManager: ShortcutManager
    private var recordingCommandID: AppCommandID?
    private var keyMonitor: Any?
    private var errorMessageByCommandID: [AppCommandID: String] = [:]

    init(configStore: AppConfigStore) {
        self.configStore = configStore
        self.shortcutManager = ShortcutManager(shortcuts: configStore.current.shortcuts)
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
        stackView.spacing = 20
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        let subtitleLabel = makeLabel(
            text: "Choose how Zentty responds to your in-app keybindings. Conflicts are blocked before they are saved.",
            font: .systemFont(ofSize: 12, weight: .regular)
        )
        subtitleLabel.textColor = .secondaryLabelColor
        stackView.addArrangedSubview(subtitleLabel)
        subtitleLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        categoryStackView.orientation = .vertical
        categoryStackView.alignment = .leading
        categoryStackView.spacing = Layout.categorySpacing
        categoryStackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(categoryStackView)
        categoryStackView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        for category in ShortcutCategory.allCases {
            let commands = AppCommandRegistry.commands(in: category)
            guard commands.isEmpty == false else {
                continue
            }

            let card = SettingsCardView()
            let titleLabel = makeLabel(
                text: category.title,
                font: .systemFont(ofSize: 13, weight: .semibold)
            )
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(titleLabel)

            let separator = SettingsGroupSeparatorView()
            card.addSubview(separator)

            let rowsStack = NSStackView()
            rowsStack.orientation = .vertical
            rowsStack.alignment = .leading
            rowsStack.spacing = 0
            rowsStack.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(rowsStack)

            for (rowIndex, command) in commands.enumerated() {
                let rowView = ShortcutBindingRowView(
                    commandID: command.id,
                    title: command.title,
                    isStriped: rowIndex.isMultiple(of: 2),
                    onRecord: { [weak self] commandID in
                        self?.beginRecording(commandID: commandID)
                    },
                    onClear: { [weak self] commandID in
                        self?.clearShortcut(for: commandID)
                    },
                    onRestoreDefault: { [weak self] commandID in
                        self?.restoreDefault(for: commandID)
                    }
                )
                rowViewsByCommandID[command.id] = rowView
                rowsStack.addArrangedSubview(rowView)
                rowView.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true

                if rowIndex < commands.count - 1 {
                    let separator = SettingsGroupSeparatorView()
                    rowsStack.addArrangedSubview(separator)
                    separator.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
                }
            }

            NSLayoutConstraint.activate([
                titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
                titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
                separator.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
                separator.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                rowsStack.topAnchor.constraint(equalTo: separator.bottomAnchor),
                rowsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                rowsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                rowsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            ])
            categoryStackView.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: categoryStackView.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])

        apply(shortcuts: currentShortcuts)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installKeyMonitorIfNeeded()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        removeKeyMonitor()
    }

    var visibleCategoryTitles: [String] {
        ShortcutCategory.allCases.map(\.title)
    }

    func displayString(for commandID: AppCommandID) -> String {
        shortcutManager.shortcut(for: commandID)?.displayString ?? "Unassigned"
    }

    func apply(shortcuts: AppConfig.Shortcuts) {
        currentShortcuts = shortcuts.normalized()
        shortcutManager = ShortcutManager(shortcuts: currentShortcuts)
        refreshRows()
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
                self.errorMessageByCommandID[recordingCommandID] = nil
                self.recordingCommandID = nil
                self.refreshRows()
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

    private func beginRecording(commandID: AppCommandID) {
        recordingCommandID = commandID
        errorMessageByCommandID[commandID] = nil
        refreshRows()
    }

    private func commit(shortcut: KeyboardShortcut, for commandID: AppCommandID) {
        guard shortcut.isEligibleCommandBinding else {
            errorMessageByCommandID[commandID] = "Shortcut must include Command, Control, or Option."
            refreshRows()
            return
        }

        if let conflict = shortcutManager.conflict(for: shortcut, assigningTo: commandID) {
            let conflictingTitle = AppCommandRegistry.definition(for: conflict.commandID).title
            errorMessageByCommandID[commandID] = "\"\(shortcut.displayString)\" is already used by \(conflictingTitle)."
            recordingCommandID = nil
            refreshRows()
            return
        }

        errorMessageByCommandID[commandID] = nil
        recordingCommandID = nil
        persistShortcut(shortcut, for: commandID)
    }

    private func clearShortcut(for commandID: AppCommandID) {
        recordingCommandID = nil
        errorMessageByCommandID[commandID] = nil
        persistShortcut(nil, for: commandID)
    }

    private func restoreDefault(for commandID: AppCommandID) {
        recordingCommandID = nil
        errorMessageByCommandID[commandID] = nil
        let defaultShortcut = AppCommandRegistry.definition(for: commandID).defaultShortcut
        persistShortcut(defaultShortcut, for: commandID)
    }

    private func persistShortcut(_ shortcut: KeyboardShortcut?, for commandID: AppCommandID) {
        try? configStore.update { config in
            config.shortcuts = config.shortcuts.updating(commandID: commandID, shortcut: shortcut)
        }
        apply(shortcuts: configStore.current.shortcuts)
    }

    private func refreshRows() {
        for definition in AppCommandRegistry.definitions {
            guard let rowView = rowViewsByCommandID[definition.id] else {
                continue
            }

            let effectiveShortcut = shortcutManager.shortcut(for: definition.id)
            let isDefault = definition.defaultShortcut == effectiveShortcut && shortcutManager.isUnbound(definition.id) == false
            rowView.render(
                shortcutDisplay: effectiveShortcut?.displayString ?? "Unassigned",
                isRecording: recordingCommandID == definition.id,
                canClear: shortcutManager.isUnbound(definition.id) == false,
                canRestoreDefault: isDefault == false,
                errorMessage: errorMessageByCommandID[definition.id]
            )
        }
    }

    private func makeLabel(text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }
}

@MainActor
private final class ShortcutBindingRowView: NSView {
    private enum Layout {
        static let topInset: CGFloat = 10
        static let sideInset: CGFloat = 16
        static let rowSpacing: CGFloat = 8
        static let titleMinimumWidth: CGFloat = 150
        static let shortcutColumnWidth: CGFloat = 108
        static let clearColumnWidth: CGFloat = 56
        static let restoreColumnWidth: CGFloat = 112
    }

    let commandID: AppCommandID

    private let titleLabel: NSTextField
    private let shortcutButton = NSButton(title: "", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let restoreButton = NSButton(title: "Restore Default", target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")
    private let backgroundView = NSView()
    private let isStriped: Bool
    private var collapsedErrorHeightConstraint: NSLayoutConstraint!
    private var collapsedBottomConstraint: NSLayoutConstraint!
    private var expandedBottomConstraint: NSLayoutConstraint!
    private let onRecord: (AppCommandID) -> Void
    private let onClear: (AppCommandID) -> Void
    private let onRestoreDefault: (AppCommandID) -> Void

    init(
        commandID: AppCommandID,
        title: String,
        isStriped: Bool,
        onRecord: @escaping (AppCommandID) -> Void,
        onClear: @escaping (AppCommandID) -> Void,
        onRestoreDefault: @escaping (AppCommandID) -> Void
    ) {
        self.commandID = commandID
        self.isStriped = isStriped
        self.onRecord = onRecord
        self.onClear = onClear
        self.onRestoreDefault = onRestoreDefault
        self.titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(backgroundView)

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        shortcutButton.bezelStyle = .rounded
        shortcutButton.controlSize = .small
        shortcutButton.target = self
        shortcutButton.action = #selector(handleRecord(_:))
        shortcutButton.setContentHuggingPriority(.required, for: .horizontal)
        shortcutButton.translatesAutoresizingMaskIntoConstraints = false
        shortcutButton.widthAnchor.constraint(equalToConstant: Layout.shortcutColumnWidth).isActive = true
        addSubview(shortcutButton)

        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(handleClear(_:))
        clearButton.setContentHuggingPriority(.required, for: .horizontal)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.widthAnchor.constraint(equalToConstant: Layout.clearColumnWidth).isActive = true
        addSubview(clearButton)

        restoreButton.bezelStyle = .rounded
        restoreButton.controlSize = .small
        restoreButton.target = self
        restoreButton.action = #selector(handleRestoreDefault(_:))
        restoreButton.setContentHuggingPriority(.required, for: .horizontal)
        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        restoreButton.widthAnchor.constraint(equalToConstant: Layout.restoreColumnWidth).isActive = true
        addSubview(restoreButton)

        errorLabel.font = .systemFont(ofSize: 11, weight: .regular)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 0
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorLabel)

        collapsedErrorHeightConstraint = errorLabel.heightAnchor.constraint(equalToConstant: 0)
        collapsedBottomConstraint = shortcutButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.topInset)
        expandedBottomConstraint = errorLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.topInset)

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            restoreButton.topAnchor.constraint(equalTo: topAnchor, constant: Layout.topInset),
            restoreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.sideInset),
            clearButton.centerYAnchor.constraint(equalTo: restoreButton.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: restoreButton.leadingAnchor, constant: -Layout.rowSpacing),
            shortcutButton.centerYAnchor.constraint(equalTo: restoreButton.centerYAnchor),
            shortcutButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -Layout.rowSpacing),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.sideInset),
            titleLabel.centerYAnchor.constraint(equalTo: restoreButton.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutButton.leadingAnchor, constant: -12),
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.titleMinimumWidth).withPriority(.defaultLow),
            errorLabel.topAnchor.constraint(equalTo: restoreButton.bottomAnchor, constant: 4),
            errorLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: restoreButton.trailingAnchor),
        ])

        collapsedErrorHeightConstraint.isActive = true
        collapsedBottomConstraint.isActive = true
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(
        shortcutDisplay: String,
        isRecording: Bool,
        canClear: Bool,
        canRestoreDefault: Bool,
        errorMessage: String?
    ) {
        shortcutButton.title = isRecording
            ? "Type Shortcut…"
            : (shortcutDisplay == "Unassigned" ? "Record Shortcut" : shortcutDisplay)
        clearButton.isEnabled = canClear
        restoreButton.isEnabled = canRestoreDefault
        errorLabel.stringValue = errorMessage ?? ""
        let showsError = errorMessage?.isEmpty == false
        errorLabel.isHidden = showsError == false
        collapsedErrorHeightConstraint.isActive = showsError == false
        collapsedBottomConstraint.isActive = showsError == false
        expandedBottomConstraint.isActive = showsError
        updateBackground()
    }

    @objc
    private func handleRecord(_ sender: Any?) {
        onRecord(commandID)
    }

    @objc
    private func handleClear(_ sender: Any?) {
        onClear(commandID)
    }

    @objc
    private func handleRestoreDefault(_ sender: Any?) {
        onRestoreDefault(commandID)
    }

    private func updateBackground() {
        let fillColor: NSColor
        if isStriped {
            if effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                fillColor = NSColor.white.withAlphaComponent(0.03)
            } else {
                fillColor = NSColor.black.withAlphaComponent(0.025)
            }
        } else {
            fillColor = .clear
        }

        backgroundView.layer?.backgroundColor = fillColor.cgColor
    }
}

@MainActor
private final class SettingsGroupSeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.separatorColor.cgColor
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> Self {
        self.priority = priority
        return self
    }
}
