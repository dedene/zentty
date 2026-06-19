import AppKit

/// Hosts the currently selected settings section in the split-view detail
/// pane, with a fixed header above the section's scroll view.
@MainActor
final class SettingsDetailContainerViewController: NSViewController {
    private let header = SettingsContentHeaderView()
    private let headerSeparator = NSBox()
    private let contentHost = NSView()
    private(set) var contentViewController: NSViewController?

    override func loadView() {
        let root = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.boxType = .separator
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(headerSeparator)
        root.addSubview(contentHost)
        NSLayoutConstraint.activate([
            // Safe-area top keeps the header below the transparent titlebar/toolbar
            // band (the window uses full-size content for the full-height sidebar).
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            headerSeparator.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            contentHost.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    /// Swaps in `viewController` as the detail content and updates the header
    /// for `section`. The section view controllers keep
    /// `translatesAutoresizingMaskIntoConstraints = true` (see
    /// `SettingsScrollableSectionViewController.loadView`), so we size the
    /// inserted view via frame + autoresizing mask — matching how the old
    /// tab shell used to drive them and avoiding the documented 0×0 blank-pane
    /// bug when a section view has no ancestor constraints.
    func setContent(_ viewController: NSViewController, section: SettingsSection) {
        _ = view
        header.configure(with: section)

        guard contentViewController !== viewController else { return }

        if let current = contentViewController {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }

        addChild(viewController)
        contentHost.layoutSubtreeIfNeeded()
        let contentView = viewController.view
        contentView.frame = contentHost.bounds
        contentView.autoresizingMask = [.width, .height]
        contentHost.addSubview(contentView)
        contentViewController = viewController
    }
}
