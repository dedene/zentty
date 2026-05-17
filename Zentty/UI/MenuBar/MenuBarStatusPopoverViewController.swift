import AppKit

@MainActor
final class MenuBarStatusPopoverViewController: NSViewController {
    private enum Layout {
        static let width: CGFloat = 320
        static let rowHeight: CGFloat = 44
    }

    private let onWorklaneSelected: (WindowID, WorklaneID) -> Void
    private let stackView = NSStackView()
    private var snapshots: [MenuBarWorklaneAgentSnapshot] = []

    init(onWorklaneSelected: @escaping (WindowID, WorklaneID) -> Void) {
        self.onWorklaneSelected = onWorklaneSelected
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: Layout.width, height: 120)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: 120))
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -8),
            stackView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -8),
        ])

        view = rootView
        rebuild()
    }

    func update(snapshots: [MenuBarWorklaneAgentSnapshot]) {
        self.snapshots = snapshots.filter(\.hasAgentPanes)
        guard isViewLoaded else { return }
        rebuild()
    }

    private func rebuild() {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if snapshots.isEmpty {
            stackView.addArrangedSubview(emptyView())
            preferredContentSize = NSSize(width: Layout.width, height: 92)
            return
        }

        for snapshot in snapshots {
            let row = MenuBarStatusPopoverRow(snapshot: snapshot)
            row.target = self
            row.action = #selector(handleRowSelected(_:))
            stackView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: Layout.rowHeight).isActive = true
        }

        let height = CGFloat(snapshots.count) * Layout.rowHeight + 16
        preferredContentSize = NSSize(width: Layout.width, height: min(max(height, 92), 420))
    }

    private func emptyView() -> NSView {
        let label = NSTextField(labelWithString: "No agent panes")
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 76),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
        ])

        return container
    }

    @objc
    private func handleRowSelected(_ sender: MenuBarStatusPopoverRow) {
        onWorklaneSelected(sender.snapshot.windowID, sender.snapshot.worklaneID)
    }
}

@MainActor
private final class MenuBarStatusPopoverRow: NSButton {
    let snapshot: MenuBarWorklaneAgentSnapshot

    init(snapshot: MenuBarWorklaneAgentSnapshot) {
        self.snapshot = snapshot
        super.init(frame: .zero)
        isBordered = false
        title = ""
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6

        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: symbolName(for: snapshot.counts),
            accessibilityDescription: nil
        )
        iconView.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        iconView.contentTintColor = tintColor(for: snapshot.counts)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: snapshot.worklaneTitle)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: snapshot.windowTitle)
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let labelStack = NSStackView(views: [titleLabel, subtitleLabel])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 1
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        let pillLabel = NSTextField(labelWithString: MenuBarStatusPresentation.statusLabel(counts: snapshot.counts))
        pillLabel.font = .systemFont(ofSize: 11, weight: .medium)
        pillLabel.alignment = .center
        pillLabel.textColor = .secondaryLabelColor
        pillLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(labelStack)
        addSubview(pillLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            labelStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelStack.trailingAnchor.constraint(lessThanOrEqualTo: pillLabel.leadingAnchor, constant: -8),

            pillLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pillLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pillLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 58),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        layer?.backgroundColor = isHighlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
    }

    private func symbolName(for counts: MenuBarAgentCounts) -> String {
        MenuBarStatusPresentation.resolve(counts: counts).symbolName
    }

    private func tintColor(for counts: MenuBarAgentCounts) -> NSColor {
        switch MenuBarStatusPresentation.resolve(counts: counts).tone {
        case .idle:
            return .secondaryLabelColor
        case .running:
            return .labelColor
        case .waiting:
            return .systemOrange
        }
    }
}
