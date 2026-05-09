import AppKit

/// Heads-up display rendered inside the zoomed-out canvas, centered below the
/// highlighted pane. Shows `proctitle • folder • branch` so the user can find
/// a pane by content while Tab-cycling. Decoupled from `WindowChromeView` —
/// the two share data sources (paneContext.presentation) but not view code.
@MainActor
final class VisualSwitcherHUDView: NSView {

    struct Content: Equatable {
        var proctitle: String?
        var folder: String?
        var branch: String?

        var isEmpty: Bool { proctitle == nil && folder == nil && branch == nil }
    }

    private let stack = NSStackView()
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

        let labels = [proctitleLabel, separator1, folderLabel, separator2, branchLabel]
        let baseFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        for label in labels {
            label.font = baseFont
            label.textColor = .white
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        separator1.textColor = NSColor.white.withAlphaComponent(0.45)
        separator2.textColor = NSColor.white.withAlphaComponent(0.45)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)

        for label in labels {
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

        // Hide separators when their flanking field is missing so the line
        // doesn't show "• • foo" with empty fragments.
        separator1.isHidden = proctitleLabel.isHidden || folderLabel.isHidden
        separator2.isHidden = folderLabel.isHidden || branchLabel.isHidden

        isHidden = content.isEmpty
    }
}
