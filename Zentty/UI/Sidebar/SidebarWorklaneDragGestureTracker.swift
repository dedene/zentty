import AppKit

@MainActor
enum SidebarWorklaneDragGestureTracker {
    private static let dragThreshold: CGFloat = 4

    static func track(
        from view: NSView,
        event: NSEvent,
        beginDrag: (NSEvent) -> Bool,
        click: () -> Void
    ) {
        guard event.type == .leftMouseDown, let window = view.window else {
            click()
            return
        }

        let initialLocation = event.locationInWindow
        while let nextEvent = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            switch nextEvent.type {
            case .leftMouseDragged:
                let distance = hypot(
                    nextEvent.locationInWindow.x - initialLocation.x,
                    nextEvent.locationInWindow.y - initialLocation.y
                )
                guard distance >= dragThreshold else {
                    continue
                }
                if beginDrag(nextEvent) == false {
                    click()
                }
                return
            case .leftMouseUp:
                click()
                return
            default:
                continue
            }
        }
    }
}
