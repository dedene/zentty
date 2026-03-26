import Foundation

// MARK: - AppNotification

struct AppNotification: Identifiable, Equatable, Sendable {
    let id: UUID
    let worklaneID: WorklaneID
    let paneID: PaneID
    let tool: AgentTool
    let interactionKind: PaneInteractionKind?
    let interactionSymbolName: String?
    let statusText: String
    let primaryText: String
    let createdAt: Date
    var isResolved: Bool = false
    var resolvedAt: Date? = nil
}

// MARK: - NotificationStore

@MainActor
final class NotificationStore {

    private(set) var notifications: [AppNotification] = []
    var onChange: (() -> Void)?

    var unresolvedCount: Int {
        notifications.count(where: { !$0.isResolved })
    }

    // MARK: - Pending debounce state

    private struct PaneKey: Hashable {
        let worklaneID: WorklaneID
        let paneID: PaneID
    }

    private var pendingNotifications: [PaneKey: AppNotification] = [:]
    private var pendingTasks: [PaneKey: Task<Void, Never>] = [:]

    private static let debounceInterval: TimeInterval = 3.0
    private static let maxItems = 50

    // MARK: - Public API

    func add(
        worklaneID: WorklaneID,
        paneID: PaneID,
        tool: AgentTool,
        interactionKind: PaneInteractionKind?,
        interactionSymbolName: String?,
        statusText: String,
        primaryText: String
    ) {
        let key = PaneKey(worklaneID: worklaneID, paneID: paneID)

        // Cancel any existing pending timer for this pane.
        cancelPending(for: key)

        let notification = AppNotification(
            id: UUID(),
            worklaneID: worklaneID,
            paneID: paneID,
            tool: tool,
            interactionKind: interactionKind,
            interactionSymbolName: interactionSymbolName,
            statusText: statusText,
            primaryText: primaryText,
            createdAt: Date()
        )

        pendingNotifications[key] = notification

        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.debounceInterval))
            guard !Task.isCancelled else { return }
            self?.commitPending(for: key)
        }
        pendingTasks[key] = task
    }

    func resolve(worklaneID: WorklaneID, paneID: PaneID) {
        let key = PaneKey(worklaneID: worklaneID, paneID: paneID)

        // If there's a pending notification, cancel and discard it silently.
        if pendingNotifications[key] != nil {
            cancelPending(for: key)
            return
        }

        // Otherwise resolve all matching unresolved committed notifications.
        let now = Date()
        var changed = false
        for i in notifications.indices where !notifications[i].isResolved
            && notifications[i].worklaneID == worklaneID
            && notifications[i].paneID == paneID
        {
            notifications[i].isResolved = true
            notifications[i].resolvedAt = now
            changed = true
        }
        if changed { onChange?() }
    }

    func dismiss(id: UUID) {
        guard let index = notifications.firstIndex(where: { $0.id == id }) else { return }
        notifications.remove(at: index)
        onChange?()
    }

    func clearAll() {
        for key in pendingTasks.keys { cancelPending(for: key) }
        guard !notifications.isEmpty else { return }
        notifications.removeAll()
        onChange?()
    }

    func mostUrgentUnresolved() -> AppNotification? {
        notifications.first(where: { !$0.isResolved })
    }

    // MARK: - Private helpers

    private func cancelPending(for key: PaneKey) {
        pendingTasks[key]?.cancel()
        pendingTasks[key] = nil
        pendingNotifications[key] = nil
    }

    private func commitPending(for key: PaneKey) {
        guard let notification = pendingNotifications[key] else { return }
        pendingNotifications[key] = nil
        pendingTasks[key] = nil

        notifications.insert(notification, at: 0)

        // Cap at maximum items — drop oldest (last in array).
        if notifications.count > Self.maxItems {
            notifications.removeLast(notifications.count - Self.maxItems)
        }

        onChange?()
    }
}
