import AppKit
import Foundation

/// Machine conditions that pause backfill (low power, thermal pressure), the free space the
/// full-disk pause waits for, and the wake-from-sleep signal that triggers a reconcile.
///
/// The indexer reads `pauseReason` on its queue before each step and re-evaluates whenever the
/// `onChange` handler fires (from any thread). Live events keep running while paused. A full
/// disk is not reported here: the indexer learns it from SQLite (`SQLITE_FULL`) and asks
/// `availableCapacity(forVolumeAt:)` before it retries.
protocol AgentHistorySystemConditions: AnyObject, Sendable {
    /// Why backfill should pause right now; nil = run.
    var pauseReason: AgentHistoryPauseReason? { get }
    /// Starts reporting changes. Calling it again replaces the handler.
    func startObserving(_ onChange: @escaping @Sendable () -> Void)
    /// Starts reporting wake from sleep (from any thread). Calling it again replaces the handler.
    func startObservingWake(_ onWake: @escaping @Sendable () -> Void)
    /// Stops reporting changes and wakes; idempotent.
    func stopObserving()
    /// Bytes available for important use on the volume holding `url` (or its nearest existing
    /// ancestor); nil when unknown.
    func availableCapacity(forVolumeAt url: URL) -> Int64?
}

/// Production conditions: Low Power Mode, thermal state `.serious` or worse, wake from sleep
/// and the volume's free space. Notifications arrive on whatever thread posts them; handlers
/// must be thread-safe (the indexer hops onto its queue).
final class LiveAgentHistorySystemConditions: AgentHistorySystemConditions, @unchecked Sendable {
    struct Readings: Sendable, Equatable {
        var isLowPowerModeEnabled: Bool
        var thermalState: ProcessInfo.ThermalState

        static func current() -> Readings {
            let info = ProcessInfo.processInfo
            return Readings(isLowPowerModeEnabled: info.isLowPowerModeEnabled, thermalState: info.thermalState)
        }
    }

    private let notificationCenter: NotificationCenter
    private let wakeNotificationCenter: NotificationCenter
    private let readings: @Sendable () -> Readings
    private let lock = NSLock()
    private var changeObservers: [any NSObjectProtocol] = []
    private var wakeObservers: [any NSObjectProtocol] = []

    /// - Parameters:
    ///   - notificationCenter: where power and thermal changes are posted.
    ///   - wakeNotificationCenter: where `NSWorkspace.didWakeNotification` is posted; nil uses
    ///     `NSWorkspace.shared.notificationCenter`.
    ///   - readings: the current power and thermal state (tests inject it).
    init(
        notificationCenter: NotificationCenter = .default,
        wakeNotificationCenter: NotificationCenter? = nil,
        readings: @escaping @Sendable () -> Readings = Readings.current
    ) {
        self.notificationCenter = notificationCenter
        self.wakeNotificationCenter = wakeNotificationCenter ?? NSWorkspace.shared.notificationCenter
        self.readings = readings
    }

    deinit {
        stopObserving()
    }

    var pauseReason: AgentHistoryPauseReason? {
        let current = readings()
        if current.isLowPowerModeEnabled {
            return .lowPower
        }
        if current.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            return .thermal
        }
        return nil
    }

    func startObserving(_ onChange: @escaping @Sendable () -> Void) {
        let names = [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification]
        let observers = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: nil) { _ in
                onChange()
            }
        }
        lock.lock()
        let previous = changeObservers
        changeObservers = observers
        lock.unlock()
        previous.forEach { notificationCenter.removeObserver($0) }
    }

    func startObservingWake(_ onWake: @escaping @Sendable () -> Void) {
        let observer = wakeNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { _ in
            onWake()
        }
        lock.lock()
        let previous = wakeObservers
        wakeObservers = [observer]
        lock.unlock()
        previous.forEach { wakeNotificationCenter.removeObserver($0) }
    }

    func stopObserving() {
        lock.lock()
        let changes = changeObservers
        let wakes = wakeObservers
        changeObservers = []
        wakeObservers = []
        lock.unlock()
        changes.forEach { notificationCenter.removeObserver($0) }
        wakes.forEach { wakeNotificationCenter.removeObserver($0) }
    }

    func availableCapacity(forVolumeAt url: URL) -> Int64? {
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate = candidate.deletingLastPathComponent()
        }
        let values = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
