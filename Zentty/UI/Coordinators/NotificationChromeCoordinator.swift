import AppKit

@MainActor
final class NotificationChromeCoordinator {
    let store: NotificationStore
    let bellButton: NotificationBellButton
    private var panelView: NotificationPanelView?
    private weak var parentView: NSView?
    private var currentTheme: ZenttyTheme?

    var onNavigateToPane: ((WorklaneID, PaneID) -> Void)?

    init(store: NotificationStore = NotificationStore(), bellButton: NotificationBellButton = NotificationBellButton()) {
        self.store = store
        self.bellButton = bellButton
    }

    func setup(parentView: NSView, theme: ZenttyTheme) {
        self.parentView = parentView
        self.currentTheme = theme

        bellButton.onClick = { [weak self] in
            self?.togglePanel()
        }
        bellButton.update(count: 0, theme: theme)
        bellButton.configure(theme: theme, animated: false)

        store.onChange = { [weak self] in
            self?.handleStoreChange()
        }
    }

    func applyTheme(_ theme: ZenttyTheme, animated: Bool) {
        currentTheme = theme
        bellButton.configure(theme: theme, animated: animated)
        bellButton.update(count: store.unresolvedCount, theme: theme)
    }

    func closePanel() {
        panelView?.close()
        panelView = nil
    }

    // MARK: - Private

    private func handleStoreChange() {
        guard let theme = currentTheme else { return }
        bellButton.update(count: store.unresolvedCount, theme: theme)
        panelView?.update(notifications: store.notifications, theme: theme)
        let count = store.unresolvedCount
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private func togglePanel() {
        if panelView != nil {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard panelView == nil, let parentView, let theme = currentTheme else { return }

        let panel = NotificationPanelView()
        panel.onJumpToLatest = { [weak self] in
            self?.jumpToLatestNotification()
        }
        panel.onClearAll = { [weak self] in
            self?.store.clearAll()
        }
        panel.onDismissNotification = { [weak self] id in
            self?.store.dismiss(id: id)
        }
        panel.onJumpToNotification = { [weak self] notification in
            self?.closePanel()
            self?.onNavigateToPane?(notification.worklaneID, notification.paneID)
        }
        panel.onClosePanel = { [weak self] in
            self?.closePanel()
        }
        panelView = panel
        panel.show(below: bellButton, in: parentView, theme: theme)
        panel.update(notifications: store.notifications, theme: theme)
    }

    private func jumpToLatestNotification() {
        guard let notification = store.mostUrgentUnresolved() else { return }
        closePanel()
        onNavigateToPane?(notification.worklaneID, notification.paneID)
    }
}
