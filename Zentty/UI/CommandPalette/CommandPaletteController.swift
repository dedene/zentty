import AppKit
import SwiftUI

@MainActor
final class CommandPaletteController {
    private static let panelWidth: CGFloat = 640
    private static let panelHeight: CGFloat = 393

    private var panel: CommandPalettePanel?
    private var hostingView: NSHostingView<CommandPaletteView>?
    private var glassSurface: GlassSurfaceView?
    private weak var parentWindow: NSWindow?
    private var clickMonitor: Any?
    private var recentCommands = RecentCommandsTracker()
    var onExecute: ((AppAction) -> Void)?

    var isShown: Bool { panel != nil }

    func show(
        in window: NSWindow,
        theme: ZenttyTheme,
        shortcutManager: ShortcutManager,
        worklaneCount: Int,
        paneCount: Int,
        focusedPanePath: String?
    ) {
        if isShown {
            close()
            return
        }

        let availableIDs = CommandAvailabilityResolver.availableCommandIDs(
            worklaneCount: worklaneCount,
            paneCount: paneCount
        )
        let allItems = CommandPaletteItemBuilder.buildItems(
            availableCommandIDs: availableIDs,
            shortcutManager: shortcutManager,
            focusedPanePath: focusedPanePath
        )
        let recentItems = recentCommands.recentCommandIDs.compactMap { commandID in
            allItems.first { $0.id == commandID }
        }
        let paletteTheme = CommandPaletteTheme(zenttyTheme: theme)

        let view = CommandPaletteView(
            items: allItems,
            recentItems: recentItems,
            theme: paletteTheme,
            onExecute: { [weak self] commandID in
                self?.executeCommand(commandID)
            },
            onDismiss: { [weak self] in
                self?.close()
            }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let glass = GlassSurfaceView(style: .commandPalette)
        glass.apply(theme: theme, animated: false)

        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.appearance = NSAppearance(named: theme.sidebarGlassAppearance.nsAppearanceName)
        containerView.addSubview(glass)
        containerView.addSubview(hosting)

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            glass.topAnchor.constraint(equalTo: containerView.topAnchor),
            glass.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: containerView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        let windowFrame = window.frame
        let panelX = windowFrame.midX - Self.panelWidth / 2
        let panelY = windowFrame.maxY - (windowFrame.height * 0.25) - Self.panelHeight

        let panelFrame = NSRect(
            x: panelX,
            y: panelY,
            width: Self.panelWidth,
            height: Self.panelHeight
        ).integral

        let newPanel = CommandPalettePanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.contentView = containerView

        containerView.frame = NSRect(origin: .zero, size: panelFrame.size)
        glass.frame = containerView.bounds
        hosting.frame = containerView.bounds

        newPanel.alphaValue = 0
        window.addChildWindow(newPanel, ordered: .above)
        newPanel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().alphaValue = 1
        }

        self.panel = newPanel
        self.hostingView = hosting
        self.glassSurface = glass
        self.parentWindow = window
        installDismissMonitor()
    }

    func close() {
        guard let panel, let parentWindow else { return }

        self.panel = nil
        self.hostingView = nil
        self.glassSurface = nil
        self.parentWindow = nil

        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            parentWindow.removeChildWindow(panel)
            panel.orderOut(nil)
        })
    }

    func updateTheme(_ theme: ZenttyTheme) {
        glassSurface?.apply(theme: theme, animated: true)
    }

    private func executeCommand(_ commandID: AppCommandID) {
        recentCommands.record(commandID)
        let action = AppCommandRegistry.definition(for: commandID).action
        close()
        onExecute?(action)
    }

    private func installDismissMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            guard event.window !== panel else { return event }
            self.close()
            return event
        }
    }
}
