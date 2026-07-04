import Foundation

struct WindowID: Hashable, Equatable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

@MainActor
protocol AgentCaffeinationScheduledHandle: AnyObject {
    func cancel()
}

@MainActor
private final class TaskAgentCaffeinationScheduledHandle: AgentCaffeinationScheduledHandle {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

@MainActor
final class AgentCaffeinationController {
    typealias ActivityToken = any NSObjectProtocol
    typealias BeginActivity = @MainActor @Sendable (_ reason: String) -> ActivityToken
    typealias EndActivity = @MainActor @Sendable (_ token: ActivityToken) -> Void
    typealias ReleaseScheduler = @MainActor @Sendable (
        _ interval: TimeInterval,
        _ operation: @escaping @MainActor () -> Void
    ) -> any AgentCaffeinationScheduledHandle

    static let shared = AgentCaffeinationController()

    private struct SourceState: Equatable {
        var enabled: Bool
        var hasRunningAgent: Bool

        var isActive: Bool {
            enabled && hasRunningAgent
        }
    }

    private let releaseDebounceInterval: TimeInterval
    private let beginActivity: BeginActivity
    private let endActivity: EndActivity
    private let releaseScheduler: ReleaseScheduler
    private var sourcesByID: [WindowID: SourceState] = [:]
    private var activityToken: ActivityToken?
    private var pendingRelease: (any AgentCaffeinationScheduledHandle)?

    init(
        releaseDebounceInterval: TimeInterval = 10,
        beginActivity: @escaping BeginActivity = AgentCaffeinationController.defaultBeginActivity,
        endActivity: @escaping EndActivity = AgentCaffeinationController.defaultEndActivity,
        releaseScheduler: @escaping ReleaseScheduler = AgentCaffeinationController.defaultReleaseScheduler
    ) {
        self.releaseDebounceInterval = releaseDebounceInterval
        self.beginActivity = beginActivity
        self.endActivity = endActivity
        self.releaseScheduler = releaseScheduler
    }

    deinit {
        MainActorShim.assumeIsolated {
            releaseNow()
        }
    }

    func setSource(id: WindowID, enabled: Bool, hasRunningAgent: Bool) {
        sourcesByID[id] = SourceState(enabled: enabled, hasRunningAgent: hasRunningAgent)
        reconcile(allowDebouncedRelease: enabled)
    }

    func removeSource(id: WindowID) {
        sourcesByID.removeValue(forKey: id)
        reconcile(allowDebouncedRelease: true)
    }

    private var hasActiveSource: Bool {
        sourcesByID.values.contains { $0.isActive }
    }

    private func reconcile(allowDebouncedRelease: Bool) {
        if hasActiveSource {
            cancelPendingRelease()
            acquireIfNeeded()
            return
        }

        guard activityToken != nil else {
            cancelPendingRelease()
            return
        }

        if allowDebouncedRelease, releaseDebounceInterval > 0 {
            scheduleReleaseIfNeeded()
        } else {
            releaseNow()
        }
    }

    private func acquireIfNeeded() {
        guard activityToken == nil else {
            return
        }

        activityToken = beginActivity("Zentty agent is running")
    }

    private func scheduleReleaseIfNeeded() {
        guard pendingRelease == nil else {
            return
        }

        pendingRelease = releaseScheduler(releaseDebounceInterval) { [weak self] in
            self?.pendingRelease = nil
            guard self?.hasActiveSource == false else {
                return
            }
            self?.releaseNow()
        }
    }

    private func releaseNow() {
        cancelPendingRelease()
        guard let token = activityToken else {
            return
        }

        activityToken = nil
        endActivity(token)
    }

    private func cancelPendingRelease() {
        pendingRelease?.cancel()
        pendingRelease = nil
    }

    private static func defaultBeginActivity(reason: String) -> ActivityToken {
        ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled,
            reason: reason
        )
    }

    private static func defaultEndActivity(_ token: ActivityToken) {
        ProcessInfo.processInfo.endActivity(token)
    }

    private static func defaultReleaseScheduler(
        interval: TimeInterval,
        operation: @escaping @MainActor () -> Void
    ) -> any AgentCaffeinationScheduledHandle {
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else {
                return
            }
            operation()
        }
        return TaskAgentCaffeinationScheduledHandle(task: task)
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

struct NotificationPaneKey: Hashable, Sendable {
    let worklaneID: WorklaneID
    let paneID: PaneID
}

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
        isDebounced: Bool = true,
        coalescesByPane: Bool = true
    ) {
        let key = PaneKey(windowID: windowID, worklaneID: worklaneID, paneID: paneID)
        let now = Date()

        let resolvedExisting: Bool
        if coalescesByPane {
            // Cancel any existing pending timer for this pane.
            cancelPending(for: key)
            resolvedExisting = resolveCommittedUnresolved(for: key, now: now)
        } else {
            resolvedExisting = false
        }

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

        guard isDebounced, coalescesByPane else {
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
        cancelPending(for: key)

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

    /// Resolves every committed unresolved notification for `windowID` and cancels
    /// its pending (debounced) notifications. Used when the window closes.
    func resolveAll(windowID: WindowID) {
        for key in pendingNotifications.keys where key.windowID == windowID {
            cancelPending(for: key)
        }

        let now = Date()
        var changed = false
        for i in notifications.indices where !notifications[i].isResolved
            && notifications[i].windowID == windowID
        {
            notifications[i].isResolved = true
            notifications[i].resolvedAt = now
            changed = true
        }
        if changed { notifyChange() }
    }

    /// Resolves every committed unresolved notification for `windowID` whose
    /// (worklaneID, paneID) is not in `liveKeys`, and cancels pending (debounced)
    /// notifications for panes that are no longer live. Used to reconcile
    /// notifications when panes or worklanes close, or panes move to another window.
    func resolveStale(windowID: WindowID, liveKeys: Set<NotificationPaneKey>) {
        for key in pendingNotifications.keys where key.windowID == windowID
            && !liveKeys.contains(NotificationPaneKey(worklaneID: key.worklaneID, paneID: key.paneID))
        {
            cancelPending(for: key)
        }

        let now = Date()
        var changed = false
        for i in notifications.indices where !notifications[i].isResolved
            && notifications[i].windowID == windowID
            && !liveKeys.contains(
                NotificationPaneKey(
                    worklaneID: notifications[i].worklaneID,
                    paneID: notifications[i].paneID
                )
            )
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
