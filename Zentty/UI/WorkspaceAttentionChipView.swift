import AppKit

final class WorkspaceAttentionChipView: NSView {
    private static let horizontalPadding: CGFloat = 10
    private let stateLabel = NSTextField(labelWithString: "")
    private let toolLabel = NSTextField(labelWithString: "")
    private let artifactButton = NSButton(title: "", target: nil, action: nil)
    private let stackView = NSStackView()
    private var artifactURL: URL?
    private var currentTheme = ZenttyTheme.fallback(for: nil)

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
        render(attention: nil)
    }

    func render(attention: WorkspaceAttentionSummary?) {
        guard let attention else {
            isHidden = true
            return
        }

        isHidden = !attention.requiresHumanAttention
        guard !isHidden else {
            return
        }

        stateLabel.stringValue = attention.statusText
        toolLabel.stringValue = attention.primaryText
        artifactURL = attention.artifactLink?.url
        artifactButton.title = attention.artifactLink?.label ?? ""
        artifactButton.isHidden = attention.artifactLink == nil

        stackView.setViews(
            [stateLabel, toolLabel, artifactButton].filter { !$0.isHidden },
            in: .leading
        )
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        stateLabel.textColor = theme.primaryText
        toolLabel.textColor = theme.secondaryText
        artifactButton.contentTintColor = theme.primaryText

        let border = theme.contextStripBorder
        let background = theme.contextStripBackground
            .mixed(towards: theme.sidebarButtonActiveBackground, amount: 0.3)

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = background.cgColor
            self.layer?.borderColor = border.cgColor
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
    var artifactTextForTesting: String { artifactButton.title }
    var preferredWidthForCurrentContent: CGFloat {
        guard !isHidden else {
            return 0
        }

        let visibleWidths = [stateLabel, toolLabel, artifactButton]
            .filter { !$0.isHidden }
            .map(\.intrinsicContentSize.width)
        let contentWidth = visibleWidths.reduce(CGFloat.zero, +)
        let spacing = CGFloat(max(0, visibleWidths.count - 1)) * stackView.spacing
        return ceil(contentWidth + spacing + (Self.horizontalPadding * 2))
    }
}
