import SwiftUI

enum NotificationPopoverMetrics {
    static let contentWidth: CGFloat = 320
    static let emptyStateHeight: CGFloat = 220
    static let populatedDefaultHeight: CGFloat = 320
    static let populatedMaxHeight: CGFloat = 460

    static func preferredHeight(forEmpty isEmpty: Bool) -> CGFloat {
        isEmpty ? emptyStateHeight : populatedDefaultHeight
    }

    static func liveHeight(forEmpty isEmpty: Bool, currentHeight: CGFloat?) -> CGFloat {
        let preferredHeight = preferredHeight(forEmpty: isEmpty)
        guard isEmpty, let currentHeight else {
            return preferredHeight
        }
        return max(preferredHeight, currentHeight)
    }
}

@MainActor
final class NotificationPopoverViewModel: ObservableObject {
    @Published private(set) var notifications: [AppNotification]
    @Published private(set) var selectedNotificationID: UUID?

    private let onJumpToLatest: () -> Void
    private let onClearAll: () -> Void
    private let onDismiss: (UUID) -> Void
    private let onActivate: (AppNotification) -> Void
    private let onClose: () -> Void

    init(
        notifications: [AppNotification],
        onJumpToLatest: @escaping () -> Void = {},
        onClearAll: @escaping () -> Void = {},
        onActivate: @escaping (AppNotification) -> Void = { _ in },
        onDismiss: @escaping (UUID) -> Void = { _ in },
        onClose: @escaping () -> Void = {}
    ) {
        self.notifications = notifications
        self.onJumpToLatest = onJumpToLatest
        self.onClearAll = onClearAll
        self.onDismiss = onDismiss
        self.onActivate = onActivate
        self.onClose = onClose
    }

    var hasNotifications: Bool {
        !notifications.isEmpty
    }

    var hasUnresolvedNotifications: Bool {
        notifications.contains(where: { !$0.isResolved })
    }

    func update(notifications: [AppNotification]) {
        self.notifications = notifications
        guard let selectedNotificationID else { return }
        if !notifications.contains(where: { $0.id == selectedNotificationID }) {
            self.selectedNotificationID = nil
        }
    }

    func moveSelection(delta: Int) {
        guard !notifications.isEmpty else {
            selectedNotificationID = nil
            return
        }

        let nextIndex: Int
        if let selectedNotificationID,
           let currentIndex = notifications.firstIndex(where: { $0.id == selectedNotificationID }) {
            nextIndex = max(0, min(notifications.count - 1, currentIndex + delta))
        } else {
            nextIndex = delta >= 0 ? 0 : notifications.count - 1
        }
        selectedNotificationID = notifications[nextIndex].id
    }

    func activateSelected() {
        guard let notification = selectedNotification else { return }
        onActivate(notification)
    }

    func dismissSelected() {
        guard let selectedNotificationID else { return }
        onDismiss(selectedNotificationID)
    }

    func jumpToLatest() {
        onJumpToLatest()
    }

    func clearAll() {
        onClearAll()
    }

    func activate(_ notification: AppNotification) {
        onActivate(notification)
    }

    func dismiss(_ id: UUID) {
        onDismiss(id)
    }

    func close() {
        onClose()
    }

    private var selectedNotification: AppNotification? {
        guard let selectedNotificationID else { return nil }
        return notifications.first(where: { $0.id == selectedNotificationID })
    }
}

struct NotificationPopoverView: View {
    @ObservedObject var viewModel: NotificationPopoverViewModel

    var body: some View {
        let isEmpty = !viewModel.hasNotifications
        let height = NotificationPopoverMetrics.preferredHeight(forEmpty: isEmpty)

        VStack(spacing: 0) {
            header
            Divider()
            if viewModel.hasNotifications {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.notifications) { notification in
                            NotificationPopoverRow(
                                notification: notification,
                                isSelected: viewModel.selectedNotificationID == notification.id,
                                onActivate: {
                                    viewModel.activate(notification)
                                },
                                onDismiss: {
                                    viewModel.dismiss(notification.id)
                                }
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(
            minWidth: NotificationPopoverMetrics.contentWidth,
            maxWidth: NotificationPopoverMetrics.contentWidth,
            minHeight: height,
            maxHeight: .infinity,
            alignment: .top
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Notifications")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Button {
                viewModel.jumpToLatest()
            } label: {
                Image(systemName: "arrow.forward.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasUnresolvedNotifications)
            .help("Jump to latest notification")

            Button {
                viewModel.clearAll()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasNotifications)
            .help("Clear notifications")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell")
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(.secondary)
            Text("No notifications")
                .font(.system(size: 14, weight: .semibold))
            Text("Agent requests and completed work will appear here.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }
}

final class NotificationPopoverHostingController: NSHostingController<NotificationPopoverView> {
    private let viewModel: NotificationPopoverViewModel

    init(viewModel: NotificationPopoverViewModel) {
        self.viewModel = viewModel
        super.init(rootView: NotificationPopoverView(viewModel: viewModel))
    }

    @available(*, unavailable)
    @MainActor
    dynamic required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func keyDown(with event: NSEvent) {
        if handleKeyDown(event) { return }
        super.keyDown(with: event)
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case 38, 125:
            viewModel.moveSelection(delta: 1)
            return true
        case 40, 126:
            viewModel.moveSelection(delta: -1)
            return true
        case 36:
            viewModel.activateSelected()
            return true
        case 51, 117:
            viewModel.dismissSelected()
            return true
        case 53:
            viewModel.close()
            return true
        default:
            return false
        }
    }
}

private struct NotificationPopoverRow: View {
    let notification: AppNotification
    let isSelected: Bool
    let onActivate: () -> Void
    let onDismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notification.interactionSymbolName ?? "bell.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(notification.isResolved ? .secondary : .accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(notification.tool.displayName)
                        .font(.system(size: 13, weight: notification.isResolved ? .regular : .medium))
                        .lineLimit(1)
                    Text(notification.statusText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text(notification.primaryText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let locationText = notification.locationText {
                    Text(locationText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(relativeTimestamp(notification.createdAt))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(minWidth: 24, alignment: .trailing)
            if isHovering {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(rowBackground)
        .opacity(notification.isResolved ? 0.55 : 1)
        .onTapGesture(perform: onActivate)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }
        if isHovering {
            return Color.primary.opacity(0.08)
        }
        return .clear
    }

    private var accessibilitySummary: String {
        [
            notification.tool.displayName,
            WorklaneContextFormatter.trimmed(notification.statusText),
            WorklaneContextFormatter.trimmed(notification.primaryText),
            WorklaneContextFormatter.trimmed(notification.locationText),
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private func relativeTimestamp(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
