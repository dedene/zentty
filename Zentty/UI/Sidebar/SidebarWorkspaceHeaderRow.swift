import AppKit

// MARK: - WorkspaceHeaderRow

private let needsInputSymbolName = "bell.badge.fill"

@MainActor
final class WorkspaceHeaderRow: NSButton {
    let workspaceID: WorkspaceID?
    var onDisclosureToggle: (() -> Void)?

    private let primaryLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusIconView = NSImageView()
    private let statusRowStack = NSStackView()
    private let contextLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()
    private let contentStack = NSStackView()
    private let artifactButton = NSButton(title: "", target: nil, action: nil)
    private let disclosureButton = NSButton()
    private let paneCountLabel = NSTextField(labelWithString: "")

    private var currentHeader: WorkspaceHeaderSummary?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var heightConstraint: NSLayoutConstraint?
    private var artifactURL: URL?
    private var isHovered = false

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
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryChange)

        primaryLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        statusIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.isHidden = true

        statusRowStack.orientation = .horizontal
        statusRowStack.alignment = .centerY
        statusRowStack.spacing = 5
        statusRowStack.translatesAutoresizingMaskIntoConstraints = false
        statusRowStack.setHuggingPriority(.defaultHigh, for: .horizontal)
        statusRowStack.addArrangedSubview(statusIconView)
        statusRowStack.addArrangedSubview(statusLabel)

        contextLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        contextLabel.lineBreakMode = .byTruncatingMiddle
        contextLabel.translatesAutoresizingMaskIntoConstraints = false

        textStack.orientation = .vertical
        textStack.spacing = ShellMetrics.sidebarRowInterlineSpacing
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false

        artifactButton.isBordered = false
        artifactButton.bezelStyle = .inline
        artifactButton.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        artifactButton.target = self
        artifactButton.action = #selector(openArtifact)
        artifactButton.setButtonType(.momentaryChange)
        artifactButton.contentTintColor = .labelColor
        artifactButton.isHidden = true

        disclosureButton.isBordered = false
        disclosureButton.bezelStyle = .regularSquare
        disclosureButton.setButtonType(.momentaryChange)
        disclosureButton.target = self
        disclosureButton.action = #selector(handleDisclosureClick)
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        disclosureButton.isHidden = true

        paneCountLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        paneCountLabel.alignment = .center
        paneCountLabel.translatesAutoresizingMaskIntoConstraints = false
        paneCountLabel.isHidden = true

        contentStack.orientation = .horizontal
        contentStack.spacing = 8
        contentStack.alignment = .centerY
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(textStack)
        contentStack.addArrangedSubview(artifactButton)

        addSubview(disclosureButton)
        addSubview(paneCountLabel)
        addSubview(contentStack)

        let defaultHeight = WorkspaceRowLayoutMetrics.sidebar.height(for: [.primary])
        let heightConstraint = heightAnchor.constraint(equalToConstant: defaultHeight)
        self.heightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            heightConstraint,

            disclosureButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 16),
            disclosureButton.heightAnchor.constraint(equalToConstant: 16),

            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ShellMetrics.sidebarRowHorizontalInset),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ShellMetrics.sidebarRowHorizontalInset),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            paneCountLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            paneCountLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(
        with header: WorkspaceHeaderSummary,
        theme: ZenttyTheme,
        animated: Bool,
        visibleRows: [WorkspaceRowTextRow],
        headerHeight: CGFloat,
        isExpanded: Bool
    ) {
        currentHeader = header
        currentTheme = theme

        primaryLabel.stringValue = header.primaryText
        statusLabel.stringValue = header.statusText ?? ""
        statusLabel.isHidden = !visibleRows.contains(.status)
        let symbolName = statusSymbolName(for: header)
        statusIconView.image = symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: header.statusText)
        }
        statusIconView.isHidden = symbolName == nil
        contextLabel.stringValue = header.gitContext
        contextLabel.isHidden = !visibleRows.contains(.context)
        artifactURL = header.artifactLink?.url
        artifactButton.title = header.artifactLink?.label ?? ""
        artifactButton.isHidden = header.artifactLink == nil

        textStack.setViews(
            visibleRows.map(view(for:)),
            in: .top
        )
        heightConstraint?.constant = headerHeight

        // Disclosure / pane count
        let showDisclosure = header.paneCount > 1
        disclosureButton.isHidden = !showDisclosure
        paneCountLabel.isHidden = !showDisclosure

        if showDisclosure {
            let chevron = isExpanded ? "chevron.down" : "chevron.right"
            disclosureButton.image = NSImage(
                systemSymbolName: chevron,
                accessibilityDescription: isExpanded ? "Collapse" : "Expand"
            )?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            paneCountLabel.stringValue = "\(header.paneCount)"
        }

        applyTextColors(theme: theme, isHovered: false)
    }

    func setDisclosureExpanded(_ expanded: Bool) {
        let chevron = expanded ? "chevron.down" : "chevron.right"
        disclosureButton.image = NSImage(
            systemSymbolName: chevron,
            accessibilityDescription: expanded ? "Collapse" : "Expand"
        )?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
    }

    func applyTextColors(theme: ZenttyTheme, isHovered: Bool) {
        guard let header = currentHeader else { return }
        currentTheme = theme

        let activeTextColor = theme.sidebarButtonActiveText
        let inactiveTextColor = theme.sidebarButtonInactiveText

        primaryLabel.textColor = header.isActive ? activeTextColor : inactiveTextColor
        contextLabel.textColor = header.isActive
            ? activeTextColor.withAlphaComponent(0.78)
            : theme.tertiaryText
        let statusColor = statusTextColor(for: header)
        statusLabel.textColor = statusColor
        statusIconView.contentTintColor = statusColor
        artifactButton.contentTintColor = header.isActive ? activeTextColor : inactiveTextColor
        disclosureButton.contentTintColor = header.isActive
            ? activeTextColor.withAlphaComponent(0.60)
            : theme.tertiaryText
        paneCountLabel.textColor = header.isActive
            ? activeTextColor.withAlphaComponent(0.60)
            : theme.tertiaryText
    }

    private func statusTextColor(for header: WorkspaceHeaderSummary) -> NSColor {
        switch header.attentionState {
        case .needsInput:
            return NSColor.systemBlue
        case .unresolvedStop:
            return NSColor.systemOrange
        case .running:
            return header.isActive
                ? currentTheme.sidebarButtonActiveText.withAlphaComponent(0.74)
                : currentTheme.secondaryText
        case .completed:
            return header.isActive
                ? currentTheme.sidebarButtonActiveText.withAlphaComponent(0.62)
                : currentTheme.tertiaryText
        case nil:
            return header.isActive
                ? currentTheme.sidebarButtonActiveText.withAlphaComponent(0.74)
                : currentTheme.secondaryText
        }
    }

    private func view(for row: WorkspaceRowTextRow) -> NSView {
        switch row {
        case .topLabel:
            return primaryLabel
        case .primary:
            return primaryLabel
        case .status:
            return statusRowStack
        case .context:
            return contextLabel
        case .detail:
            return contextLabel
        case .overflow:
            return contextLabel
        }
    }

    private func statusSymbolName(for header: WorkspaceHeaderSummary) -> String? {
        switch header.attentionState {
        case .needsInput:
            return needsInputSymbolName
        default:
            return nil
        }
    }

    @objc
    private func openArtifact() {
        guard let artifactURL else { return }
        NSWorkspace.shared.open(artifactURL)
    }

    @objc
    private func handleDisclosureClick() {
        onDisclosureToggle?()
    }

    // MARK: - Testing Accessors

    var primaryTextForTesting: String {
        primaryLabel.stringValue
    }

    var artifactTextForTesting: String {
        artifactButton.title
    }

    var attentionSymbolNameForTesting: String? {
        switch currentHeader?.attentionState {
        case .needsInput:
            return needsInputSymbolName
        default:
            return nil
        }
    }

    func primaryMinX(in view: NSView) -> CGFloat {
        view.convert(primaryLabel.bounds, from: primaryLabel).minX
    }
}
