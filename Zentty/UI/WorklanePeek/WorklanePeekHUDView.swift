import AppKit

/// Heads-up display rendered inside the zoomed-out canvas, centered below the
/// highlighted pane. Shows `proctitle • folder • branch` so the user can find
/// a pane by content while Tab-cycling. Decoupled from `WindowChromeView` —
/// the two share data sources (paneContext.presentation) but not view code.
@MainActor
final class WorklanePeekHUDView: NSView {

    struct Content: Equatable {
        var proctitle: String?
        var folder: String?
        var branch: String?
        var icon: NSImage?

        var isEmpty: Bool {
            proctitle == nil && folder == nil && branch == nil && icon == nil
        }

        static func == (lhs: Content, rhs: Content) -> Bool {
            lhs.proctitle == rhs.proctitle
                && lhs.folder == rhs.folder
                && lhs.branch == rhs.branch
                && lhs.icon === rhs.icon
        }
    }

    private let stack = NSStackView()
    private let iconView = NSImageView()
    private let proctitleLabel = NSTextField(labelWithString: "")
    private let separator1 = NSTextField(labelWithString: "•")
    private let folderLabel = NSTextField(labelWithString: "")
    private let separator2 = NSTextField(labelWithString: "•")
    private let branchLabel = NSTextField(labelWithString: "")
    private let backgroundLayer = CAShapeLayer()

    var content: Content = Content() {
        didSet {
            guard content != oldValue else { return }
            applyContent()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configure() {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 10

        // Weight hierarchy: proctitle anchors the scan, folder is contextual,
        // branch is the lightest hint. Keeping fields the same point size
        // keeps baselines aligned in the single-line layout.
        let allLabels = [proctitleLabel, separator1, folderLabel, separator2, branchLabel]
        for label in allLabels {
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        proctitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        proctitleLabel.textColor = .white
        folderLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        folderLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        branchLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        branchLabel.textColor = NSColor.white.withAlphaComponent(0.65)
        separator1.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        separator2.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        separator1.textColor = NSColor.white.withAlphaComponent(0.4)
        separator2.textColor = NSColor.white.withAlphaComponent(0.4)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.wantsLayer = true
        iconView.layer?.masksToBounds = false
        iconView.layer?.shadowOffset = .zero
        iconView.layer?.shadowColor = NSColor.white.withAlphaComponent(0.55).cgColor
        iconView.layer?.shadowRadius = 2
        iconView.layer?.shadowOpacity = 0

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)

        stack.addArrangedSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])
        stack.setCustomSpacing(10, after: iconView)

        for label in allLabels {
            stack.addArrangedSubview(label)
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyContent()
    }

    private func applyContent() {
        proctitleLabel.stringValue = content.proctitle ?? ""
        folderLabel.stringValue = content.folder ?? ""
        branchLabel.stringValue = content.branch ?? ""

        proctitleLabel.isHidden = (content.proctitle ?? "").isEmpty
        folderLabel.isHidden = (content.folder ?? "").isEmpty
        branchLabel.isHidden = (content.branch ?? "").isEmpty

        iconView.image = content.icon
        iconView.isHidden = content.icon == nil
        iconView.layer?.shadowOpacity = content.icon == nil ? 0 : 0.55

        // Hide separators when their flanking field is missing so the line
        // doesn't show "• • foo" with empty fragments.
        separator1.isHidden = proctitleLabel.isHidden || folderLabel.isHidden
        separator2.isHidden = folderLabel.isHidden || branchLabel.isHidden

        isHidden = content.isEmpty
    }
}
