import AppKit

/// Container for the four leading chrome controls: sidebar toggle, pane
/// layout menu, pane navigation, notification inbox. Owns the inter-button
/// spacings and exposes a single anchor point so the surrounding sidebar-
/// motion code only has to move one view instead of chaining four.
@MainActor
final class LeadingChromeControlsBar: NSView {
    private static let toggleToLayoutSpacing: CGFloat = 4
    private static let layoutToNavigationSpacing: CGFloat = 4
    private static let navigationToInboxSpacing: CGFloat = 8

    static let totalWidth: CGFloat =
        SidebarToggleButton.buttonSize
        + toggleToLayoutSpacing + PaneLayoutMenuButton.buttonSize
        + layoutToNavigationSpacing + PaneNavigationButtons.totalWidth
        + navigationToInboxSpacing + NotificationInboxButton.buttonSize

    static let height: CGFloat = SidebarToggleButton.buttonSize

    init(
        toggle: SidebarToggleButton,
        layoutMenu: PaneLayoutMenuButton,
        navigation: PaneNavigationButtons,
        inbox: NotificationInboxButton
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        [toggle, layoutMenu, navigation, inbox].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: SidebarToggleButton.buttonSize),
            toggle.heightAnchor.constraint(equalToConstant: SidebarToggleButton.buttonSize),

            layoutMenu.leadingAnchor.constraint(
                equalTo: toggle.trailingAnchor,
                constant: Self.toggleToLayoutSpacing
            ),
            layoutMenu.centerYAnchor.constraint(equalTo: centerYAnchor),
            layoutMenu.widthAnchor.constraint(equalToConstant: PaneLayoutMenuButton.buttonSize),
            layoutMenu.heightAnchor.constraint(equalToConstant: PaneLayoutMenuButton.buttonSize),

            navigation.leadingAnchor.constraint(
                equalTo: layoutMenu.trailingAnchor,
                constant: Self.layoutToNavigationSpacing
            ),
            navigation.centerYAnchor.constraint(equalTo: centerYAnchor),
            navigation.widthAnchor.constraint(equalToConstant: PaneNavigationButtons.totalWidth),
            navigation.heightAnchor.constraint(equalToConstant: PaneNavigationButtons.buttonSize),

            inbox.leadingAnchor.constraint(
                equalTo: navigation.trailingAnchor,
                constant: Self.navigationToInboxSpacing
            ),
            inbox.trailingAnchor.constraint(equalTo: trailingAnchor),
            inbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            inbox.widthAnchor.constraint(equalToConstant: NotificationInboxButton.buttonSize),
            inbox.heightAnchor.constraint(equalToConstant: NotificationInboxButton.buttonSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.totalWidth, height: Self.height)
    }

    /// Pass mouse events in inter-button gaps through to whatever sits
    /// underneath, preserving today's behaviour where empty space in this
    /// region was simply root-view background.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let inside = super.hitTest(point)
        return inside === self ? nil : inside
    }
}
