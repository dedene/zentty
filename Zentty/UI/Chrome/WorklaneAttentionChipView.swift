import AppKit

struct WorklaneAttentionChipPresentation: Equatable {
    var statusText: String?
    var toolText: String
    var artifactLabel: String?
    var artifactURL: URL?
    var interactionKind: PaneInteractionKind?
    var interactionLabel: String?
    var interactionSymbolName: String?
    var attentionState: WorklaneAttentionState?

    init(
        statusText: String?,
        toolText: String,
        artifactLabel: String?,
        artifactURL: URL?,
        interactionKind: PaneInteractionKind? = nil,
        interactionLabel: String? = nil,
        interactionSymbolName: String? = nil,
        attentionState: WorklaneAttentionState? = nil
    ) {
        self.statusText = statusText
        self.toolText = toolText
        self.artifactLabel = artifactLabel
        self.artifactURL = artifactURL
        self.interactionKind = interactionKind
        self.interactionLabel = interactionLabel
        self.interactionSymbolName = interactionSymbolName
        self.attentionState = attentionState
    }
}

@MainActor
final class WorklaneAttentionChipView: NSView {
    private static let horizontalPadding: CGFloat = 10
    private static let symbolPointSize: CGFloat = 11

    private let stateIconView = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let toolLabel = NSTextField(labelWithString: "")
    private let artifactButton = NSButton(title: "", target: nil, action: nil)
    private let stackView = NSStackView()
    private var artifactURL: URL?
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var currentAttentionState: WorklaneAttentionState?
    private var currentStateSymbolName = ""

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
        layer?.cornerRadius = ChromeGeometry.pillRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        stateIconView.translatesAutoresizingMaskIntoConstraints = false
        stateIconView.imageScaling = .scaleProportionallyDown
        stateIconView.setContentHuggingPriority(.required, for: .horizontal)
        stateIconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        stateLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        toolLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        toolLabel.lineBreakMode = .byTruncatingTail
        toolLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        artifactButton.isBordered = false
        artifactButton.bezelStyle = .inline
        artifactButton.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        artifactButton.target = self
        artifactButton.action = #selector(openArtifact)

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        let leadingConstraint = stackView.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Self.horizontalPadding
        )
        leadingConstraint.priority = .defaultHigh

        let trailingConstraint = stackView.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -Self.horizontalPadding
        )
        trailingConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            leadingConstraint,
            trailingConstraint,
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        apply(theme: currentTheme, animated: false)
        render(presentation: nil)
    }

    func render(attention: WorklaneAttentionSummary?) {
        guard let attention else {
            render(presentation: nil)
            return
        }

        guard attention.requiresHumanAttention else {
            isHidden = true
            return
        }

        render(
            presentation: WorklaneAttentionChipPresentation(
                statusText: attention.statusText,
                toolText: attention.primaryText,
                artifactLabel: attention.artifactLink?.label,
                artifactURL: attention.artifactLink?.url,
                interactionKind: attention.interactionKind,
                interactionLabel: attention.interactionLabel,
                interactionSymbolName: attention.interactionSymbolName,
                attentionState: attention.state
            )
        )
    }

    func render(presentation: WorklaneAttentionChipPresentation?) {
        guard let presentation else {
            isHidden = true
            artifactURL = nil
            currentAttentionState = nil
            currentStateSymbolName = ""
            stateLabel.stringValue = ""
            toolLabel.stringValue = ""
            artifactButton.title = ""
            artifactButton.isHidden = true
            stateIconView.image = nil
            stateIconView.isHidden = true
            stackView.setViews([], in: .leading)
            return
        }

        isHidden = false
        currentAttentionState = presentation.attentionState
        stateLabel.stringValue = WorklaneContextFormatter.trimmed(presentation.statusText)
            ?? presentation.interactionLabel
            ?? presentation.interactionKind?.defaultLabel
            ?? ""
        toolLabel.stringValue = presentation.toolText
        artifactURL = presentation.artifactURL
        artifactButton.title = presentation.artifactLabel ?? ""
        artifactButton.isHidden = presentation.artifactLabel == nil

        let symbolName = presentation.interactionSymbolName
            ?? presentation.interactionKind?.defaultSymbolName
        currentStateSymbolName = symbolName ?? ""
        stateIconView.image = symbolName.flatMap { symbolImage(for: $0) }
        stateIconView.isHidden = stateIconView.image == nil

        stackView.setViews(
            [stateIconView, stateLabel, toolLabel, artifactButton].filter { !$0.isHidden },
            in: .leading
        )

        applyStatusColors(animated: false)
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        applyStatusColors(animated: animated)
    }

    private func applyStatusColors(animated: Bool) {
        let theme = currentTheme
        let statusColor = chipStatusColor(for: currentAttentionState, theme: theme)
        stateLabel.textColor = statusColor
        toolLabel.textColor = theme.secondaryText
        stateIconView.contentTintColor = statusColor
        artifactButton.contentTintColor = theme.primaryText

        let baseBackground = theme.contextStripBackground
            .mixed(towards: theme.sidebarButtonActiveBackground, amount: 0.3)
        let background = baseBackground.mixed(towards: statusColor, amount: 0.12)
        let border = theme.contextStripBorder.mixed(towards: statusColor, amount: 0.22)

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = background.cgColor
            self.layer?.borderColor = border.cgColor
        }
    }

    private func chipStatusColor(
        for attentionState: WorklaneAttentionState?,
        theme: ZenttyTheme
    ) -> NSColor {
        switch attentionState {
        case .running:
            return theme.statusRunning
        case .needsInput:
            return theme.statusNeedsInput
        case .unresolvedStop:
            return theme.statusStopped
        case .ready:
            return theme.statusReady
        case nil:
            return theme.primaryText
        }
    }

    @objc
    private func openArtifact() {
        guard let artifactURL else {
            return
        }

        NSWorkspace.shared.open(artifactURL)
    }

    var stateTextForTesting: String { stateLabel.stringValue }
    var stateSymbolNameForTesting: String { currentStateSymbolName }
    var toolTextForTesting: String { toolLabel.stringValue }
    var artifactTextForTesting: String { artifactButton.title }
    var preferredWidthForCurrentContent: CGFloat {
        guard !isHidden else {
            return 0
        }

        let visibleWidths = [stateIconView, stateLabel, toolLabel, artifactButton]
            .filter { !$0.isHidden }
            .map(\.intrinsicContentSize.width)
        let contentWidth = visibleWidths.reduce(CGFloat.zero, +)
        let spacing = CGFloat(max(0, visibleWidths.count - 1)) * stackView.spacing
        return ceil(contentWidth + spacing + (Self.horizontalPadding * 2))
    }

    private func symbolImage(for symbolName: String) -> NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.symbolPointSize, weight: .semibold))
    }
}
