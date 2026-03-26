import AppKit

struct OpenWithPopoverItem {
    let stableID: String
    let title: String
    let icon: NSImage?
    let isEnabled: Bool
    let isSelected: Bool
}

@MainActor
final class OpenWithPopoverController: NSObject {
    private let contentController = OpenWithPopoverContentViewController()
    private weak var parentWindow: NSWindow?
    private weak var panel: OpenWithPopoverPanel?
    private weak var anchorView: NSView?
    private var anchorRectInView: NSRect = .zero
    private var clickMonitor: Any?
    var onSelectTarget: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?

    override init() {
        super.init()
        contentController.onSelectTarget = { [weak self] stableID in
            self?.close()
            self?.onSelectTarget?(stableID)
        }
        contentController.onOpenSettings = { [weak self] in
            self?.close()
            self?.onOpenSettings?()
        }
        contentController.onDismissRequested = { [weak self] in
            self?.close()
        }
    }

    func show(
        relativeTo positioningRect: NSRect,
        of view: NSView,
        theme: ZenttyTheme,
        items: [OpenWithPopoverItem]
    ) {
        if isShown {
            close()
            return
        }

        guard let parentWindow = view.window else {
            return
        }

        contentController.render(theme: theme, items: items)
        let size = contentController.preferredPopoverSize
        let anchorRectInWindow = view.convert(positioningRect, to: nil)
        let anchorOrigin = parentWindow.convertPoint(toScreen: anchorRectInWindow.origin)
        let anchorRectOnScreen = NSRect(origin: anchorOrigin, size: anchorRectInWindow.size)

        close()

        let panel = OpenWithPopoverPanel(
            contentRect: frame(for: anchorRectOnScreen, size: size, screen: parentWindow.screen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = contentController
        panel.setFrame(frame(for: anchorRectOnScreen, size: size, screen: parentWindow.screen), display: false)
        parentWindow.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)

        self.parentWindow = parentWindow
        self.panel = panel
        self.anchorView = view
        self.anchorRectInView = positioningRect
        installDismissMonitor()
        DispatchQueue.main.async { [weak self] in
            self?.contentController.focusList()
        }
    }

    func close() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }

        if let panel, let parentWindow {
            parentWindow.removeChildWindow(panel)
            panel.orderOut(nil)
        }

        self.panel = nil
        self.parentWindow = nil
        self.anchorView = nil
        self.anchorRectInView = .zero
    }

    func performSettingsActionForTesting() {
        contentController.performSettingsActionForTesting()
    }

    func dismissWithEscapeForTesting() {
        contentController.dismissWithEscapeForTesting()
        close()
    }

    func performOutsideClickDismissalForTesting() {
        close()
    }

    func moveSelectionDownForTesting() {
        contentController.moveSelectionDownForTesting()
    }

    func activateSelectionForTesting() {
        contentController.activateSelectionForTesting()
    }

    func simulateHoverRowForTesting(stableID: String) {
        contentController.simulateHoverRowForTesting(stableID: stableID)
    }

    func simulateExitRowForTesting(stableID: String) {
        contentController.simulateExitRowForTesting(stableID: stableID)
    }

    func simulateHoverSettingsForTesting() {
        contentController.simulateHoverSettingsForTesting()
    }

    var isShown: Bool {
        panel != nil
    }

    var selectedStableIDForTesting: String? {
        contentController.selectedStableIDForTesting
    }

    var enabledStableIDsForTesting: [String] {
        contentController.enabledStableIDsForTesting
    }

    var disabledStableIDsForTesting: [String] {
        contentController.disabledStableIDsForTesting
    }

    var highlightedStableIDForTesting: String? {
        contentController.highlightedStableIDForTesting
    }

    var settingsBackgroundTokenForTesting: String {
        contentController.settingsBackgroundTokenForTesting
    }

    var settingsBorderTokenForTesting: String {
        contentController.settingsBorderTokenForTesting
    }

    func rowBackgroundTokenForTesting(stableID: String) -> String {
        contentController.rowBackgroundTokenForTesting(stableID: stableID)
    }

    func rowBorderTokenForTesting(stableID: String) -> String {
        contentController.rowBorderTokenForTesting(stableID: stableID)
    }

    private func frame(for anchorRectOnScreen: NSRect, size: NSSize, screen: NSScreen?) -> NSRect {
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var originX = anchorRectOnScreen.maxX - size.width
        var originY = anchorRectOnScreen.minY - 6 - size.height

        if visibleFrame.width > 0 {
            originX = min(max(originX, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        }

        if visibleFrame.height > 0 {
            originY = max(originY, visibleFrame.minY + 8)
        }

        return NSRect(origin: NSPoint(x: originX, y: originY), size: size).integral
    }

    private func installDismissMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard
                let self,
                let panel
            else {
                return event
            }

            guard event.window !== panel else {
                return event
            }

            if
                event.window === self.parentWindow,
                let anchorView = self.anchorView
            {
                let pointInAnchorView = anchorView.convert(event.locationInWindow, from: nil)
                if self.anchorRectInView.contains(pointInAnchorView) {
                    self.close()
                    return nil
                }
            }

            self.close()
            return event
        }
    }
}

private final class OpenWithPopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing bufferingType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: bufferingType, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        hidesOnDeactivate = false
        collectionBehavior = [.transient, .moveToActiveSpace]
    }
}
