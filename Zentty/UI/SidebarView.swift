import AppKit

final class SidebarView: NSView {
    var onSelectWorkspace: ((WorkspaceID) -> Void)?
    var onCreateWorkspace: (() -> Void)?
    var onResizeWidth: ((CGFloat) -> Void)?

    private let headerLabel = NSTextField(labelWithString: "Workspaces")
    private let addWorkspaceButton = NSButton(title: "+", target: nil, action: nil)
    private let listScrollView = NSScrollView()
    private let listStack = NSStackView()
    private let dividerView = NSView()
    private let resizeHandleView = SidebarResizeHandleView()

    private var workspaceButtons: [WorkspaceRowButton] = []
    private var workspaceSummaries: [WorkspaceSidebarSummary] = []
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var resizeStartWidth: CGFloat = SidebarWidthPreference.defaultWidth

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = currentTheme.sidebarBackground.cgColor

        headerLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        addWorkspaceButton.isBordered = false
        addWorkspaceButton.bezelStyle = .regularSquare
        addWorkspaceButton.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        addWorkspaceButton.wantsLayer = true
        addWorkspaceButton.translatesAutoresizingMaskIntoConstraints = false
        addWorkspaceButton.target = self
        addWorkspaceButton.action = #selector(handleCreateWorkspace)

        listStack.orientation = .vertical
        listStack.alignment = .width
        listStack.spacing = 8
        listStack.translatesAutoresizingMaskIntoConstraints = false

        listScrollView.drawsBackground = false
        listScrollView.hasVerticalScroller = true
        listScrollView.autohidesScrollers = true
        listScrollView.translatesAutoresizingMaskIntoConstraints = false
        listScrollView.documentView = listStack

        dividerView.wantsLayer = true
        dividerView.translatesAutoresizingMaskIntoConstraints = false

        resizeHandleView.translatesAutoresizingMaskIntoConstraints = false
        resizeHandleView.onPan = { [weak self] recognizer in
            self?.handleResizePan(recognizer)
        }

        addSubview(headerLabel)
        addSubview(addWorkspaceButton)
        addSubview(listScrollView)
        addSubview(dividerView)
        addSubview(resizeHandleView)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            addWorkspaceButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            addWorkspaceButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            addWorkspaceButton.widthAnchor.constraint(equalToConstant: 28),
            addWorkspaceButton.heightAnchor.constraint(equalToConstant: 28),

            listScrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 14),
            listScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            listScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            listScrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            listStack.topAnchor.constraint(equalTo: listScrollView.contentView.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: listScrollView.contentView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listScrollView.contentView.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: listScrollView.contentView.bottomAnchor),
            listStack.widthAnchor.constraint(equalTo: listScrollView.contentView.widthAnchor),

            dividerView.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            dividerView.widthAnchor.constraint(equalToConstant: 1),

            resizeHandleView.topAnchor.constraint(equalTo: topAnchor),
            resizeHandleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 4),
            resizeHandleView.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandleView.widthAnchor.constraint(equalToConstant: 12),
        ])

        apply(theme: currentTheme, animated: false)
    }

    func render(
        summaries: [WorkspaceSidebarSummary],
        theme: ZenttyTheme
    ) {
        workspaceSummaries = summaries
        apply(theme: theme, animated: true)

        workspaceButtons.forEach { button in
            listStack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        workspaceButtons.removeAll(keepingCapacity: true)

        for summary in summaries {
            let button = WorkspaceRowButton(workspaceID: summary.workspaceID)
            button.target = self
            button.action = #selector(handleWorkspaceButton(_:))
            button.configure(with: summary, theme: currentTheme, animated: false)
            workspaceButtons.append(button)
            listStack.addArrangedSubview(button)
        }
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        guard theme != currentTheme else {
            return
        }

        currentTheme = theme
        headerLabel.textColor = theme.secondaryText
        addWorkspaceButton.contentTintColor = theme.secondaryText

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = theme.sidebarBackground.cgColor
            self.dividerView.layer?.backgroundColor = theme.canvasBorder.withAlphaComponent(0.55).cgColor
            self.addWorkspaceButton.layer?.backgroundColor = theme.sidebarButtonInactiveBackground.cgColor
            self.addWorkspaceButton.layer?.borderColor = theme.paneBorderUnfocused.cgColor
            self.addWorkspaceButton.layer?.borderWidth = 1
        }

        addWorkspaceButton.layer?.cornerRadius = 14
        addWorkspaceButton.layer?.cornerCurve = .continuous

        workspaceButtons.enumerated().forEach { index, button in
            guard workspaceSummaries.indices.contains(index) else {
                return
            }
            button.configure(with: workspaceSummaries[index], theme: theme, animated: animated)
        }
    }

    @objc
    private func handleWorkspaceButton(_ sender: WorkspaceRowButton) {
        guard let workspaceID = sender.workspaceID else {
            return
        }

        onSelectWorkspace?(workspaceID)
    }

    @objc
    private func handleCreateWorkspace() {
        onCreateWorkspace?()
    }

    private func handleResizePan(_ recognizer: NSPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            resizeStartWidth = bounds.width
        case .changed, .ended:
            let translation = recognizer.translation(in: self).x
            onResizeWidth?(SidebarWidthPreference.clamped(resizeStartWidth + translation))
        default:
            break
        }
    }

    var workspaceTitlesForTesting: [String] {
        workspaceSummaries.map(\.title)
    }

    var activeWorkspaceTitleForTesting: String? {
        workspaceSummaries.first(where: \.isActive)?.title
    }

    var workspaceButtonsForTesting: [NSButton] {
        workspaceButtons
    }
}

private final class WorkspaceRowButton: NSButton {
    let workspaceID: WorkspaceID?

    private let badgeContainer = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let paneCountLabel = NSTextField(labelWithString: "")

    init(workspaceID: WorkspaceID?) {
        self.workspaceID = workspaceID
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        image = nil
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryChange)

        badgeContainer.wantsLayer = true
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.layer?.cornerRadius = 11
        badgeContainer.layer?.cornerCurve = .continuous

        badgeLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        paneCountLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        paneCountLabel.alignment = .right
        paneCountLabel.translatesAutoresizingMaskIntoConstraints = false
        paneCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, summaryLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(badgeContainer)
        badgeContainer.addSubview(badgeLabel)
        addSubview(textStack)
        addSubview(paneCountLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 68),

            badgeContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            badgeContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeContainer.widthAnchor.constraint(equalToConstant: 34),
            badgeContainer.heightAnchor.constraint(equalToConstant: 34),

            badgeLabel.centerXAnchor.constraint(equalTo: badgeContainer.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: paneCountLabel.leadingAnchor, constant: -10),

            paneCountLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            paneCountLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(
        with summary: WorkspaceSidebarSummary,
        theme: ZenttyTheme,
        animated: Bool
    ) {
        badgeLabel.stringValue = summary.badgeText
        titleLabel.stringValue = summary.title
        summaryLabel.stringValue = summary.attentionText ?? summary.summaryText
        detailLabel.stringValue = summary.detailText
        paneCountLabel.stringValue = summary.paneCountText
        paneCountLabel.isHidden = summary.paneCountText == summary.detailText

        titleLabel.textColor = theme.tertiaryText
        summaryLabel.textColor = summary.isActive ? theme.primaryText : theme.secondaryText
        detailLabel.textColor = theme.tertiaryText
        paneCountLabel.textColor = theme.tertiaryText
        badgeLabel.textColor = summary.isActive ? theme.sidebarButtonActiveText : theme.secondaryText

        let activeBackground = theme.sidebarButtonActiveBackground
        let inactiveBackground = theme.sidebarButtonInactiveBackground
        let activeBorder = theme.sidebarButtonActiveBorder
        let inactiveBorder = theme.paneBorderUnfocused.withAlphaComponent(0.28)

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = (summary.isActive ? activeBackground : inactiveBackground).cgColor
            self.layer?.borderColor = (summary.isActive ? activeBorder : inactiveBorder).cgColor
            self.layer?.borderWidth = 1
            self.badgeContainer.layer?.backgroundColor = (
                summary.isActive
                    ? theme.workspaceChipBackground
                    : theme.canvasBackground.mixed(towards: theme.primaryText, amount: 0.08)
            ).cgColor
        }
    }
}

private final class SidebarResizeHandleView: NSView {
    var onPan: ((NSPanGestureRecognizer) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let recognizer = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(recognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    @objc
    private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        onPan?(recognizer)
    }
}
