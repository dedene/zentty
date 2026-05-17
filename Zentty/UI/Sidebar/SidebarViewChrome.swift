import AppKit

@MainActor
final class SidebarViewChrome {
    private weak var hostView: NSView?
    private let backgroundView: GlassSurfaceView
    private let listScrollView: NSScrollView
    private let listDocumentView: FlippedSidebarDocumentView
    private let listStack: NSStackView
    private let addWorklaneButton: SidebarCreateWorklaneButton
    private let globalSearchButton: SidebarGlobalSearchButton
    private let globalSearchRowView: SidebarGlobalSearchRowView
    private let bookmarksButton: SidebarBookmarksButton
    private let updateAvailableRowView: SidebarUpdateAvailableRowView
    private let resizeHandleView: SidebarResizeHandleView

    init(
        hostView: NSView,
        backgroundView: GlassSurfaceView,
        listScrollView: NSScrollView,
        listDocumentView: FlippedSidebarDocumentView,
        listStack: NSStackView,
        addWorklaneButton: SidebarCreateWorklaneButton,
        globalSearchButton: SidebarGlobalSearchButton,
        globalSearchRowView: SidebarGlobalSearchRowView,
        bookmarksButton: SidebarBookmarksButton,
        updateAvailableRowView: SidebarUpdateAvailableRowView,
        resizeHandleView: SidebarResizeHandleView
    ) {
        self.hostView = hostView
        self.backgroundView = backgroundView
        self.listScrollView = listScrollView
        self.listDocumentView = listDocumentView
        self.listStack = listStack
        self.addWorklaneButton = addWorklaneButton
        self.globalSearchButton = globalSearchButton
        self.globalSearchRowView = globalSearchRowView
        self.bookmarksButton = bookmarksButton
        self.updateAvailableRowView = updateAvailableRowView
        self.resizeHandleView = resizeHandleView
    }

    func apply(theme: ZenttyTheme, animated: Bool) {
        let sidebarAppearance = NSAppearance(named: theme.sidebarGlassAppearance.nsAppearanceName)
        hostView?.appearance = sidebarAppearance
        listScrollView.appearance = sidebarAppearance
        listDocumentView.appearance = sidebarAppearance
        listStack.appearance = sidebarAppearance
        addWorklaneButton.configure(theme: theme, animated: animated)
        globalSearchButton.configure(theme: theme, animated: animated)
        globalSearchRowView.apply(theme: theme, animated: animated)
        bookmarksButton.configure(theme: theme, animated: animated)
        updateAvailableRowView.configure(theme: theme, animated: animated)
        resizeHandleView.apply(theme: theme, animated: animated)
        backgroundView.apply(theme: theme, animated: animated)

        performThemeAnimation(animated: animated) {
            self.hostView?.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
