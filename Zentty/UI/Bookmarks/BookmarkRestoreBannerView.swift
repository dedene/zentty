import AppKit

@MainActor
final class BookmarkRestoreBannerView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)
    private let onEdit: () -> Void
    private weak var hostView: NSView?

    init(fallbackCount: Int, onEdit: @escaping () -> Void) {
        self.onEdit = onEdit
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0
        layer?.backgroundColor = NSColor.windowBackgroundColor
            .withSystemEffect(.deepPressed)
            .cgColor

        translatesAutoresizingMaskIntoConstraints = false

        let pluralized = fallbackCount == 1 ? "fallback" : "fallbacks"
        label.stringValue = "Bookmark restored with \(fallbackCount) \(pluralized)."
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 2

        editButton.bezelStyle = .rounded
        editButton.controlSize = .small
        editButton.target = self
        editButton.action = #selector(handleEdit)
        editButton.translatesAutoresizingMaskIntoConstraints = false

        dismissButton.bezelStyle = .rounded
        dismissButton.controlSize = .small
        dismissButton.target = self
        dismissButton.action = #selector(handleDismiss)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [label, editButton, dismissButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(over host: NSView) {
        // Banners share an anchor, so only the latest restore stays on screen.
        host.subviews
            .filter { $0 is BookmarkRestoreBannerView && $0 !== self }
            .forEach { $0.removeFromSuperview() }
        hostView = host
        host.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor, constant: 16),
            centerXAnchor.constraint(equalTo: host.centerXAnchor),
            widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -32),
        ])

        // Auto-dismiss after 12 seconds if user doesn't interact.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.removeFromSuperview()
        }
    }

    @objc private func handleEdit() {
        onEdit()
        removeFromSuperview()
    }

    @objc private func handleDismiss() {
        removeFromSuperview()
    }
}
