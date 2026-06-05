import AppKit

@MainActor
final class SidebarWorklaneRowMenuController: NSObject {
    var onCloseWorklaneRequested: (() -> Void)?
    var onRenameWorklaneRequested: (() -> Void)?
    var onWorklaneColorChanged: ((WorklaneID, WorklaneColor?) -> Void)?
    var onWorklaneMoveRequested: ((WorklaneID, SidebarWorklaneMoveDirection) -> Void)?
    var onBookmarkAction: ((WorklaneID, SidebarBookmarkRowAction) -> Void)?
    var bookmarkNameLookup: ((UUID) -> String?)?

    private var currentWorklaneID: WorklaneID?
    private(set) var activeContextPicker: WorklaneColorMenuItemView?

    func makeMenu(
        worklaneID: WorklaneID?,
        summary: WorklaneSidebarSummary?,
        moveAvailability: SidebarWorklaneMoveAvailability
    ) -> NSMenu? {
        guard let worklaneID else {
            currentWorklaneID = nil
            activeContextPicker = nil
            return nil
        }
        currentWorklaneID = worklaneID
        activeContextPicker = nil

        let originID = summary?.bookmarkOriginID
        let result = SidebarWorklaneContextMenu.makeMenu(
            context: SidebarWorklaneContextMenuContext(
                origin: .worklane,
                moveAvailability: moveAvailability,
                worklaneColor: summary?.color,
                bookmarkOriginID: originID,
                bookmarkName: originID.flatMap { bookmarkNameLookup?($0) },
                isOnlyWorklane: false
            ),
            actions: SidebarWorklaneContextMenuActions(
                target: self,
                runRestoredCommandAction: nil,
                renameWorklaneAction: #selector(handleRenameWorklane),
                closeWorklaneAction: #selector(handleCloseWorklane),
                closePaneAction: nil,
                moveUpAction: #selector(handleMoveWorklaneUp),
                moveDownAction: #selector(handleMoveWorklaneDown),
                splitHorizontalAction: nil,
                splitVerticalAction: nil,
                forceSplitRightAction: nil,
                forceAddPaneRightAction: nil,
                movePaneToNewWindowAction: nil,
                bookmarkAction: #selector(handleBookmarkMenuItem(_:)),
                colorChanged: { [weak self] picked in
                    guard let self, let worklaneID = self.currentWorklaneID else { return }
                    self.onWorklaneColorChanged?(worklaneID, picked)
                }
            )
        )
        activeContextPicker = result.activePicker
        return result.menu
    }

    @objc
    private func handleCloseWorklane() {
        onCloseWorklaneRequested?()
    }

    @objc
    private func handleRenameWorklane() {
        onRenameWorklaneRequested?()
    }

    @objc
    private func handleBookmarkMenuItem(_ sender: NSMenuItem) {
        guard let worklaneID = currentWorklaneID,
              let box = sender.representedObject as? SidebarBookmarkRowActionBox else {
            return
        }
        onBookmarkAction?(worklaneID, box.action)
    }

    @objc
    private func handleMoveWorklaneUp() {
        guard let worklaneID = currentWorklaneID else { return }
        onWorklaneMoveRequested?(worklaneID, .up)
    }

    @objc
    private func handleMoveWorklaneDown() {
        guard let worklaneID = currentWorklaneID else { return }
        onWorklaneMoveRequested?(worklaneID, .down)
    }
}
