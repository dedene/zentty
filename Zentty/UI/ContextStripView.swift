import AppKit

final class ContextStripView: NSView {
    static let preferredHeight: CGFloat = 24

    private let focusedLabel = ContextStripView.makeLabel(text: "shell", color: .secondaryLabelColor, weight: .medium)
    private let cwdLabel = ContextStripView.makeLabel(text: "", color: .tertiaryLabelColor, weight: .regular)
    private let branchLabel = ContextStripView.makeLabel(text: "branch", color: .tertiaryLabelColor, weight: .regular)
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
        layer?.backgroundColor = currentTheme.contextStripBackground.cgColor

        let stack = NSStackView(views: [focusedLabel, cwdLabel, branchLabel])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        apply(theme: currentTheme, animated: false)
    }

    func render(workspaceName: String, state: PaneStripState, metadata: TerminalMetadata?) {
        let focusedTitle = metadata?.title
            ?? metadata?.processName
            ?? state.focusedPane?.title
            ?? "pane"
        let hasExactPathContext = metadata?.currentWorkingDirectory?.isEmpty == false
            || metadata?.gitBranch?.isEmpty == false

        if hasExactPathContext {
            focusedLabel.stringValue = ""
            focusedLabel.isHidden = true
        } else {
            focusedLabel.stringValue = focusedTitle
            focusedLabel.isHidden = focusedTitle.isEmpty
        }
        if let cwd = metadata?.currentWorkingDirectory, !cwd.isEmpty {
            cwdLabel.stringValue = "cwd \(Self.compactPath(cwd))"
            cwdLabel.isHidden = false
        } else {
            cwdLabel.stringValue = ""
            cwdLabel.isHidden = true
        }
        if let branch = metadata?.gitBranch, !branch.isEmpty {
            branchLabel.stringValue = "branch \(branch)"
            branchLabel.isHidden = false
        } else {
            branchLabel.isHidden = true
        }
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        focusedLabel.textColor = theme.secondaryText
        cwdLabel.textColor = theme.tertiaryText
        branchLabel.textColor = theme.tertiaryText

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = theme.contextStripBackground.cgColor
        }
    }

    var workspaceTextForTesting: String { "" }
    var focusedTextForTesting: String { focusedLabel.stringValue }
    var cwdTextForTesting: String { cwdLabel.stringValue }
    var branchTextForTesting: String { branchLabel.stringValue }
    var isFocusedHiddenForTesting: Bool { focusedLabel.isHidden }
    var isBranchHiddenForTesting: Bool { branchLabel.isHidden }

    private static func makeLabel(
        text: String,
        color: NSColor,
        weight: NSFont.Weight
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private static func compactPath(_ path: String) -> String {
        let homeDirectory = NSHomeDirectory()
        guard path.hasPrefix(homeDirectory) else {
            return path
        }

        return path.replacingOccurrences(of: homeDirectory, with: "~")
    }
}
