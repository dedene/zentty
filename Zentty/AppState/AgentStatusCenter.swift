import Foundation

@MainActor
final class AgentStatusCenter: NSObject {
    var onPayload: ((AgentStatusPayload) -> Void)?

    private let center: DistributedNotificationCenter
    private var hasStarted = false

    init(center: DistributedNotificationCenter = .default()) {
        self.center = center
        super.init()
    }

    func start() {
        guard !hasStarted else {
            return
        }

        center.addObserver(
            self,
            selector: #selector(handleDistributedNotification(_:)),
            name: AgentStatusTransport.notificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        hasStarted = true
    }

    deinit {
        if hasStarted {
            center.removeObserver(
                self,
                name: AgentStatusTransport.notificationName,
                object: nil
            )
        }
    }

    @objc
    private func handleDistributedNotification(_ notification: Notification) {
        handle(notification: notification)
    }

    private func handle(notification: Notification) {
        guard let userInfo = notification.userInfo else {
            return
        }

        guard let payload = try? AgentStatusPayload(userInfo: userInfo) else {
            return
        }

        Task { @MainActor [weak self] in
            self?.onPayload?(payload)
        }
    }
}
