import AppKit

final class SidebarView: NSView {
    var onSelectWorkspace: ((WorkspaceID) -> Void)?
    var onCreateWorkspace: (() -> Void)?

    private let stack = NSStackView()
    private var workspaceButtons: [WorkspaceButton] = []
    private weak var addWorkspaceButton: WorkspaceButton?
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
        layer?.backgroundColor = currentTheme.sidebarBackground.cgColor

        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    func render(workspaces: [WorkspaceState], activeWorkspaceID: WorkspaceID, theme: ZenttyTheme) {
        apply(theme: theme, animated: true)
        stack.arrangedSubviews.forEach { arrangedSubview in
            stack.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }
        workspaceButtons = []

        for workspace in workspaces {
            let button = WorkspaceButton(workspaceID: workspace.id)
            button.title = workspace.title
            configure(button)
            applyStyle(to: button, isActive: workspace.id == activeWorkspaceID, animated: false)
            button.target = self
            button.action = #selector(handleWorkspaceButton(_:))
            workspaceButtons.append(button)
            stack.addArrangedSubview(button)
        }

        let addButton = WorkspaceButton(workspaceID: nil)
        addButton.title = "+"
        configure(addButton)
        applyStyle(to: addButton, isActive: false, animated: false)
        addButton.target = self
        addButton.action = #selector(handleWorkspaceButton(_:))
        stack.addArrangedSubview(addButton)
        addWorkspaceButton = addButton
    }

    @objc
    private func handleWorkspaceButton(_ sender: WorkspaceButton) {
        if let workspaceID = sender.workspaceID {
            onSelectWorkspace?(workspaceID)
        } else {
            onCreateWorkspace?()
        }
    }

    private func configure(_ button: WorkspaceButton) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.alignment = .center
        button.wantsLayer = true
        button.layer?.cornerRadius = 16
        button.layer?.cornerCurve = .continuous
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 58),
            button.widthAnchor.constraint(equalToConstant: 56),
        ])
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        guard theme != currentTheme else {
            return
        }
        currentTheme = theme
        performThemeAnimation(animated: animated) {
            self.layer?.backgroundColor = theme.sidebarBackground.cgColor
        }
        workspaceButtons.forEach { button in
            let isActive = button.layer?.borderWidth == 1
            applyStyle(to: button, isActive: isActive, animated: animated)
        }
        if let addWorkspaceButton {
            applyStyle(to: addWorkspaceButton, isActive: false, animated: animated)
        }
    }

    private func applyStyle(to button: WorkspaceButton, isActive: Bool, animated: Bool) {
        button.font = NSFont.systemFont(ofSize: 12, weight: isActive ? .semibold : .medium)
        button.contentTintColor = isActive ? currentTheme.sidebarButtonActiveText : currentTheme.sidebarButtonInactiveText
        performThemeAnimation(animated: animated) {
            button.layer?.backgroundColor = (isActive
                ? self.currentTheme.sidebarButtonActiveBackground
                : self.currentTheme.sidebarButtonInactiveBackground
            ).cgColor
            button.layer?.borderWidth = isActive ? 1 : 0
            button.layer?.borderColor = self.currentTheme.sidebarButtonActiveBorder.cgColor
        }
    }

    var workspaceTitlesForTesting: [String] {
        workspaceButtons.map(\.title)
    }

    var activeWorkspaceTitleForTesting: String? {
        workspaceButtons.first(where: { $0.layer?.borderWidth == 1 })?.title
    }

    var workspaceButtonsForTesting: [NSButton] {
        workspaceButtons
    }
}

private final class WorkspaceButton: NSButton {
    let workspaceID: WorkspaceID?

    init(workspaceID: WorkspaceID?) {
        self.workspaceID = workspaceID
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
