import Foundation

struct AppUpdateState: Equatable, Sendable {
    var isUpdateAvailable = false
}

@MainActor
final class AppUpdateStateStore {
    private(set) var current = AppUpdateState()
    private var observers: [UUID: @MainActor (AppUpdateState) -> Void] = [:]

    @discardableResult
    func addObserver(_ handler: @escaping @MainActor (AppUpdateState) -> Void) -> UUID {
        let observerID = UUID()
        observers[observerID] = handler
        return observerID
    }

    func removeObserver(_ observerID: UUID) {
        observers.removeValue(forKey: observerID)
    }

    func setUpdateAvailable(_ isUpdateAvailable: Bool) {
        guard current.isUpdateAvailable != isUpdateAvailable else {
            return
        }

        current.isUpdateAvailable = isUpdateAvailable
        observers.values.forEach { $0(current) }
    }
}
