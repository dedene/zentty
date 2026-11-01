import AppKit
import Combine
import SwiftUI

/// The Agent History palette's child panel: the command palette's panel, glass and backdrop
/// with a SwiftUI body. Every keyDown in the panel goes through `AgentHistoryKeyRouter` first,
/// so arrows, ↩ and ⇥ drive the list while the search field keeps focus.
///
/// Shows the consent card's "Add Folder…" picker through an injectable `folderPicker`.
typealias AgentHistoryPaletteFolderPicker = @MainActor (_ parent: NSWindow?, _ completion: @escaping @MainActor ([URL]) -> Void) -> Void

@MainActor
final class AgentHistoryPanelController {
    /// Until the consent card reports its measured height.
    static let defaultConsentHeight: CGFloat = 520
    static let fadeInDuration: TimeInterval = 0.15
    static let fadeOutDuration: TimeInterval = 0.10
    static let announcementInterval: TimeInterval = 1

    private var panel: CommandPalettePanel?
    private var containerView: NSView?
    private var glassSurface: GlassSurfaceView?
    private weak var backdropView: CommandPaletteBackdropView?
    private weak var parentWindow: NSWindow?
    private var model: AgentHistoryViewModel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var exemptClickViews: () -> [NSView] = { [] }
    private var isDismissMonitorSuspended = false
    private var isPresentingFolderPicker = false
    private var windowObservers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var pendingAnnouncement: String?
    private var announcementWork: AgentHistoryCancellable?
    private var lastAnnouncementAt: Date?

    /// Called once per close, whoever closed the panel (esc, click outside, the parent window).
    var onClosed: (() -> Void)?

    var isShown: Bool { panel != nil }

    /// Hosted tests swap in a stub that mimics the open panel taking key focus.
    var folderPicker: AgentHistoryPaletteFolderPicker = AgentHistoryPanelController.openPanelFolderPicker

    static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Show and close

    func show(
        in window: NSWindow,
        backdropView: CommandPaletteBackdropView,
        theme: ZenttyTheme,
        model: AgentHistoryViewModel,
        exemptClickViews: @escaping () -> [NSView]
    ) {
        if isShown {
            close(animated: false)
        }

        let layout = AgentHistoryPanelLayout.resolve(windowFrame: window.frame, mode: Self.mode(for: model))
        model.layout = layout
        model.updateTheme(theme)

        let hosting = NSHostingView(rootView: AgentHistoryView(model: model))
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let glass = GlassSurfaceView(style: .commandPalette)
        glass.apply(theme: theme, animated: false)
        glass.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.appearance = NSAppearance(named: theme.sidebarGlassAppearance.nsAppearanceName)
        container.addSubview(glass)
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let newPanel = CommandPalettePanel(
            contentRect: layout.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.contentView = container
        newPanel.setAccessibilityLabel("Agent History")
        container.frame = NSRect(origin: .zero, size: layout.frame.size)

        let animates = !Self.reducesMotion
        backdropView.apply(theme: theme, animated: false)
        backdropView.setVisible(true, animated: animates)

        newPanel.alphaValue = animates ? 0 : 1
        window.addChildWindow(newPanel, ordered: .above)
        newPanel.makeKeyAndOrderFront(nil)
        if animates {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeInDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                newPanel.animator().alphaValue = 1
            }
        }

        panel = newPanel
        containerView = container
        glassSurface = glass
        self.backdropView = backdropView
        parentWindow = window
        self.model = model
        self.exemptClickViews = exemptClickViews
        isDismissMonitorSuspended = false
        installKeyMonitor()
        installDismissMonitor()
        observe(window: window)
        observe(model: model)
        model.start()
    }

    func close(animated: Bool) {
        guard let panel else { return }
        let backdrop = backdropView
        let parent = parentWindow
        let closingModel = model

        self.panel = nil
        containerView = nil
        glassSurface = nil
        backdropView = nil
        parentWindow = nil
        model = nil
        exemptClickViews = { [] }
        removeMonitors()
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
        cancellables = []
        announcementWork?.cancel()
        announcementWork = nil
        pendingAnnouncement = nil

        closingModel?.stop()
        let animates = animated && !Self.reducesMotion
        backdrop?.setVisible(false, animated: animates)

        if animates, let parent {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.fadeOutDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActorShim.assumeIsolated {
                    parent.removeChildWindow(panel)
                    panel.orderOut(nil)
                }
            })
        } else {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        onClosed?()
    }

    func updateTheme(_ theme: ZenttyTheme) {
        glassSurface?.apply(theme: theme, animated: true)
        backdropView?.apply(theme: theme, animated: true)
        containerView?.appearance = NSAppearance(named: theme.sidebarGlassAppearance.nsAppearanceName)
        model?.updateTheme(theme)
    }

    /// Fits the panel to the parent window and the body (results or the consent card).
    func relayout() {
        guard let panel, let parentWindow, let model else { return }
        let layout = AgentHistoryPanelLayout.resolve(windowFrame: parentWindow.frame, mode: Self.mode(for: model))
        if model.layout != layout {
            model.layout = layout
        }
        if panel.frame != layout.frame {
            panel.setFrame(layout.frame, display: true)
        }
    }

    /// While an `NSOpenPanel` is up, clicks in it must not dismiss the palette.
    func setDismissMonitorSuspended(_ suspended: Bool) {
        isDismissMonitorSuspended = suspended
    }

    static func mode(for model: AgentHistoryViewModel) -> AgentHistoryPanelLayout.Mode {
        guard model.body == .consent else { return .results }
        return .consent(fittingHeight: model.consentFittingHeight ?? defaultConsentHeight)
    }

    // MARK: - Folder picker

    /// "Add Folder…": clicks in the picker must not dismiss the palette, and when it closes the
    /// palette takes key focus back (the picker leaves the parent window key otherwise).
    func presentFolderPicker(_ completion: @escaping @MainActor ([URL]) -> Void) {
        guard let panel, !isPresentingFolderPicker else { return }
        isPresentingFolderPicker = true
        setDismissMonitorSuspended(true)
        folderPicker(parentWindow) { [weak self, weak panel] urls in
            guard let self else { return }
            self.isPresentingFolderPicker = false
            self.setDismissMonitorSuspended(false)
            guard let panel, panel === self.panel else { return }
            panel.makeKey()
            self.model?.requestQueryFocus()
            completion(urls)
        }
    }

    static func openPanelFolderPicker(_ parent: NSWindow?, _ completion: @escaping @MainActor ([URL]) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = true
        openPanel.canCreateDirectories = false
        openPanel.prompt = "Exclude"
        openPanel.message = "Choose folders whose agent sessions Agent History should never index."
        openPanel.begin { response in
            let urls = response == .OK ? openPanel.urls : []
            MainActorShim.assumeIsolated { completion(urls) }
        }
    }

    // MARK: - Keys

    /// Routes a keyDown to the model; false lets the search field have it.
    @discardableResult
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard let panel, let model else { return false }
        let context = Self.keyContext(editor: panel.firstResponder as? NSTextView, model: model)
        guard let command = AgentHistoryKeyRouter.command(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            context: context
        ) else {
            return Self.swallowsUnroutedKey(modifiers: event.modifierFlags, context: context)
        }
        model.handle(command)
        return true
    }

    /// While the folder-gone sheet is up, plain typing must not edit the query hidden behind it;
    /// ⌘ and ⌃ shortcuts still reach the app, and an input method finishes its composition.
    static func swallowsUnroutedKey(modifiers: NSEvent.ModifierFlags, context: AgentHistoryKeyContext) -> Bool {
        context.isSheetShown && !context.hasMarkedText && modifiers.intersection([.command, .control]).isEmpty
    }

    static func keyContext(editor: NSTextView?, model: AgentHistoryViewModel) -> AgentHistoryKeyContext {
        var context = AgentHistoryKeyContext()
        if let editor {
            let selection = editor.selectedRange()
            context.caretAtEndOfQuery = NSMaxRange(selection) >= (editor.string as NSString).length
            context.hasTextSelection = selection.length > 0
            context.hasMarkedText = editor.hasMarkedText()
        }
        context.isTranscriptShown = model.detail == .transcript
        context.isSheetShown = model.folderSheet != nil
        context.bodyIsResults = model.body == .results
        return context
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            return self.handleKeyEvent(event) ? nil : event
        }
    }

    // MARK: - Dismissal

    private func installDismissMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, !self.isDismissMonitorSuspended else { return event }
            guard event.window !== panel, !self.isExemptClick(event) else { return event }
            self.close(animated: true)
            return event
        }
    }

    /// Clicks on the toolbar button toggle the palette themselves.
    private func isExemptClick(_ event: NSEvent) -> Bool {
        exemptClickViews().contains { view in
            guard let window = view.window, window === event.window else { return false }
            let point = view.convert(event.locationInWindow, from: nil)
            return view.bounds.contains(point)
        }
    }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    // MARK: - Observation

    private func observe(window: NSWindow) {
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActorShim.assumeIsolated { self?.relayout() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActorShim.assumeIsolated { self?.close(animated: false) }
            },
        ]
    }

    private func observe(model: AgentHistoryViewModel) {
        model.$body
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                // `@Published` emits before the value is stored.
                DispatchQueue.main.async {
                    MainActorShim.assumeIsolated { self?.relayout() }
                }
            }
            .store(in: &cancellables)
        model.$consentFittingHeight
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    MainActorShim.assumeIsolated { self?.relayout() }
                }
            }
            .store(in: &cancellables)
        model.$sections
            .dropFirst()
            .sink { [weak self] sections in
                MainActorShim.assumeIsolated { self?.sectionsDidChange(sections) }
            }
            .store(in: &cancellables)
    }

    /// VoiceOver hears "‹n› sessions found" for typed queries, at most once a second.
    private func sectionsDidChange(_ sections: [AgentHistorySection]) {
        guard let model, !model.query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let count = sections.reduce(0) { $0 + $1.rows.count }
        pendingAnnouncement = Self.announcement(forResultCount: count)
        guard announcementWork == nil else { return }
        let elapsed = lastAnnouncementAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let delay = max(0.25, Self.announcementInterval - elapsed)
        announcementWork = AgentHistoryMainQueueScheduler().schedule(after: delay) { [weak self] in
            self?.postAnnouncement()
        }
    }

    private func postAnnouncement() {
        announcementWork = nil
        guard let panel, let text = pendingAnnouncement else { return }
        pendingAnnouncement = nil
        lastAnnouncementAt = Date()
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    static func announcement(forResultCount count: Int) -> String {
        switch count {
        case 0: "No sessions found"
        case 1: "1 session found"
        default: "\(count) sessions found"
        }
    }
}
