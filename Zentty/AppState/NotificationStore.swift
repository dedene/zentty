import Foundation

struct WindowID: Hashable, Equatable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

// MARK: - AppNotification

struct AppNotification: Identifiable, Equatable, Sendable {
    let id: UUID
    let windowID: WindowID
    let worklaneID: WorklaneID
    let paneID: PaneID
    let state: WorklaneAttentionState
    let tool: AgentTool
    let interactionKind: PaneInteractionKind?
    let interactionSymbolName: String?
    let statusText: String
    let primaryText: String
    let locationText: String?
    let createdAt: Date
    var isResolved: Bool = false
    var resolvedAt: Date? = nil

    init(
        id: UUID,
        windowID: WindowID,
        worklaneID: WorklaneID,
        paneID: PaneID,
        state: WorklaneAttentionState,
        tool: AgentTool,
        interactionKind: PaneInteractionKind?,
        interactionSymbolName: String?,
        statusText: String,
        primaryText: String,
        locationText: String? = nil,
        createdAt: Date,
        isResolved: Bool = false,
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.windowID = windowID
        self.worklaneID = worklaneID
        self.paneID = paneID
        self.state = state
        self.tool = tool
        self.interactionKind = interactionKind
        self.interactionSymbolName = interactionSymbolName
        self.statusText = statusText
        self.primaryText = primaryText
        self.locationText = locationText
        self.createdAt = createdAt
        self.isResolved = isResolved
        self.resolvedAt = resolvedAt
    }
}

// MARK: - NotificationStore

@MainActor
final class NotificationStore {

    private(set) var notifications: [AppNotification] = []
    var onChange: (() -> Void)?
    private var observers: [UUID: () -> Void] = [:]

    var unresolvedCount: Int {
        notifications.count(where: { !$0.isResolved })
    }

    // MARK: - Pending debounce state

    private struct PaneKey: Hashable {
        let windowID: WindowID
        let worklaneID: WorklaneID
        let paneID: PaneID
    }

    private var pendingNotifications: [PaneKey: AppNotification] = [:]
    private var pendingTasks: [PaneKey: Task<Void, Never>] = [:]

    private let debounceInterval: TimeInterval
    private static let maxItems = 50

    init(debounceInterval: TimeInterval = 3.0) {
        self.debounceInterval = debounceInterval
    }

    // MARK: - Public API

    func add(
        windowID: WindowID,
        worklaneID: WorklaneID,
        paneID: PaneID,
        state: WorklaneAttentionState,
        tool: AgentTool,
        interactionKind: PaneInteractionKind?,
        interactionSymbolName: String?,
        statusText: String,
        primaryText: String,
        locationText: String? = nil,
        isDebounced: Bool = true
    ) {
        let key = PaneKey(windowID: windowID, worklaneID: worklaneID, paneID: paneID)
        let now = Date()

        // Cancel any existing pending timer for this pane.
        cancelPending(for: key)
        let resolvedExisting = resolveCommittedUnresolved(for: key, now: now)

        let notification = AppNotification(
            id: UUID(),
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: paneID,
            state: state,
            tool: tool,
            interactionKind: interactionKind,
            interactionSymbolName: interactionSymbolName,
            statusText: statusText,
            primaryText: primaryText,
            locationText: locationText,
            createdAt: now
        )

        guard isDebounced else {
            notifications.insert(notification, at: 0)
            trimIfNeeded()
            notifyChange()
            return
        }

        pendingNotifications[key] = notification

        let interval = debounceInterval
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            self?.commitPending(for: key)
        }
        pendingTasks[key] = task

        if resolvedExisting {
            notifyChange()
        }
    }

    func resolve(windowID: WindowID, worklaneID: WorklaneID, paneID: PaneID) {
        let key = PaneKey(windowID: windowID, worklaneID: worklaneID, paneID: paneID)

        if pendingNotifications[key] != nil {
            cancelPending(for: key)
            return
        }

        let now = Date()
        var changed = false
        for i in notifications.indices where !notifications[i].isResolved
            && notifications[i].windowID == windowID
            && notifications[i].worklaneID == worklaneID
            && notifications[i].paneID == paneID
        {
            notifications[i].isResolved = true
            notifications[i].resolvedAt = now
            changed = true
        }
        if changed { notifyChange() }
    }

    func resolve(worklaneID: WorklaneID, paneID: PaneID) {
        let now = Date()
        var changed = false
        for key in pendingNotifications.keys where key.worklaneID == worklaneID && key.paneID == paneID {
            cancelPending(for: key)
        }
        for i in notifications.indices where !notifications[i].isResolved
            && notifications[i].worklaneID == worklaneID
            && notifications[i].paneID == paneID
        {
            notifications[i].isResolved = true
            notifications[i].resolvedAt = now
            changed = true
        }
        if changed { notifyChange() }
    }

    func dismiss(id: UUID) {
        guard let index = notifications.firstIndex(where: { $0.id == id }) else { return }
        notifications.remove(at: index)
        notifyChange()
    }

    func clearAll() {
        for key in pendingTasks.keys { cancelPending(for: key) }
        guard !notifications.isEmpty else { return }
        notifications.removeAll()
        notifyChange()
    }

    func mostUrgentUnresolved() -> AppNotification? {
        notifications.first(where: { !$0.isResolved })
    }

    func addObserver(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
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
        trimIfNeeded()

        notifyChange()
    }

    private func resolveCommittedUnresolved(for key: PaneKey, now: Date) -> Bool {
        var changed = false
        for i in notifications.indices where !notifications[i].isResolved
            && notifications[i].windowID == key.windowID
            && notifications[i].worklaneID == key.worklaneID
            && notifications[i].paneID == key.paneID
        {
            notifications[i].isResolved = true
            notifications[i].resolvedAt = now
            changed = true
        }
        return changed
    }

    private func trimIfNeeded() {
        if notifications.count > Self.maxItems {
            notifications.removeLast(notifications.count - Self.maxItems)
        }
    }

    private func notifyChange() {
        onChange?()
        for observer in observers.values {
            observer()
        }
    }
}
