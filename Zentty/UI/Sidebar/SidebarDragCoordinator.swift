import AppKit

@MainActor
final class SidebarDragCoordinator {
    private weak var sidebarView: SidebarView?

    init(sidebarView: SidebarView) {
        self.sidebarView = sidebarView
    }

    func beginDrag(button: SidebarWorklaneRowButton, event: NSEvent) -> Bool {
        guard let sidebarView,
              let window = sidebarView.window,
              let draggedID = button.worklaneID
        else {
            return false
        }

        let initialOrder = sidebarView.currentWorklaneOrder()
        guard initialOrder.count > 1, initialOrder.contains(draggedID) else {
            return false
        }

        let pointInButton = button.convert(event.locationInWindow, from: nil)
        let verticalOffset = pointInButton.y
        var latestPreviewOrder = initialOrder

        sidebarView.prepareDraggedWorklaneButton(button)
        defer {
            sidebarView.finishDraggedWorklaneButton(button)
            sidebarView.clearDragPreview()
        }

        updateDrag(
            windowLocation: event.locationInWindow,
            draggedID: draggedID,
            initialOrder: initialOrder,
            latestPreviewOrder: &latestPreviewOrder,
            button: button,
            verticalOffset: verticalOffset
        )

        while let nextEvent = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            switch nextEvent.type {
            case .leftMouseDragged:
                updateDrag(
                    windowLocation: nextEvent.locationInWindow,
                    draggedID: draggedID,
                    initialOrder: initialOrder,
                    latestPreviewOrder: &latestPreviewOrder,
                    button: button,
                    verticalOffset: verticalOffset
                )
            case .leftMouseUp:
                guard let targetIndex = latestPreviewOrder.firstIndex(of: draggedID) else {
                    return true
                }
                _ = sidebarView.commitWorklaneReorder(id: draggedID, toIndex: targetIndex)
                return true
            default:
                continue
            }
        }

        return true
    }

    private func updateDrag(
        windowLocation: NSPoint,
        draggedID: WorklaneID,
        initialOrder: [WorklaneID],
        latestPreviewOrder: inout [WorklaneID],
        button: SidebarWorklaneRowButton,
        verticalOffset: CGFloat
    ) {
        guard let sidebarView else {
            return
        }

        sidebarView.positionDraggedWorklaneButton(
            button,
            atWindowLocation: windowLocation,
            verticalOffset: verticalOffset
        )

        let cursorInReorderSpace = sidebarView.reorderPoint(fromWindowLocation: windowLocation)
        let insertionIndex = SidebarWorklaneReorderModel.insertionIndex(
            cursorY: cursorInReorderSpace.y,
            rowFrames: sidebarView.worklaneRowFramesForReordering(),
            draggedID: draggedID
        )
        guard let previewOrder = SidebarWorklaneReorderModel.previewOrder(
            currentOrder: initialOrder,
            draggedID: draggedID,
            insertionIndex: insertionIndex
        ) else {
            return
        }

        latestPreviewOrder = previewOrder
        sidebarView.setDragPreview(draggedID: draggedID, previewOrder: previewOrder)

        let visibleRect = sidebarView.visibleListRectForReordering()
        let velocity = SidebarWorklaneReorderModel.autoScrollVelocity(
            cursorY: cursorInReorderSpace.y,
            visibleMinY: visibleRect.minY,
            visibleMaxY: visibleRect.maxY
        )
        if velocity != 0 {
            sidebarView.adjustScrollOffset(by: velocity / 60)
        }
    }
}
