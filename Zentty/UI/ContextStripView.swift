import AppKit

final class ContextStripView: NSView {
    static let preferredHeight: CGFloat = 34

    private let workspaceChip = ContextStripView.makeChip(text: "API")
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

        let stack = NSStackView(views: [workspaceChip, focusedLabel, cwdLabel, branchLabel])
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
        workspaceChip.stringValue = workspaceName
        let focusedTitle = metadata?.title
            ?? metadata?.processName
            ?? state.focusedPane?.title
            ?? "pane"

        focusedLabel.stringValue = focusedTitle
        focusedLabel.isHidden = focusedTitle.isEmpty
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
        workspaceChip.textColor = theme.workspaceChipText
        focusedLabel.textColor = theme.secondaryText
        cwdLabel.textColor = theme.tertiaryText
        branchLabel.textColor = theme.tertiaryText

        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = theme.contextStripBackground.cgColor
            self.workspaceChip.layer?.backgroundColor = theme.workspaceChipBackground.cgColor
        }
    }

    var workspaceTextForTesting: String { workspaceChip.stringValue }
    var focusedTextForTesting: String { focusedLabel.stringValue }
    var cwdTextForTesting: String { cwdLabel.stringValue }
    var branchTextForTesting: String { branchLabel.stringValue }
    var isBranchHiddenForTesting: Bool { branchLabel.isHidden }

    private static func makeChip(text: String) -> NSTextField {
        let chip = NSTextField(labelWithString: text)
        chip.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        chip.textColor = .labelColor
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.11).cgColor
        chip.layer?.cornerRadius = 11
        chip.layer?.cornerCurve = .continuous
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.setContentHuggingPriority(.required, for: .horizontal)
        chip.lineBreakMode = .byTruncatingMiddle
        NSLayoutConstraint.activate([
            chip.heightAnchor.constraint(equalToConstant: 24),
        ])
        return chip
    }

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
