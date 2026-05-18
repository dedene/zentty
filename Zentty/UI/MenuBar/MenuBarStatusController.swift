import AppKit
import OSLog

@MainActor
struct MenuBarWorklaneSource {
    let windowID: WindowID
    let windowTitle: String
    let worklaneStore: WorklaneStore
}

@MainActor
final class MenuBarStatusController: NSObject {
    private static let logger = Logger(subsystem: "be.zenjoy.zentty", category: "MenuBarStatus")

    private let configStore: AppConfigStore
    private let focusWorklaneHandler: (WindowID, WorklaneID) -> Void
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var popoverViewController: MenuBarStatusPopoverViewController?
    private var sources: [MenuBarWorklaneSource] = []
    private var subscriptions: [WindowID: (store: WorklaneStore, subscription: WorklaneChangeSubscription)] = [:]
    private var isStarted = false
    private var latestSnapshots: [MenuBarWorklaneAgentSnapshot] = []

    init(
        configStore: AppConfigStore,
        focusWorklaneHandler: @escaping (WindowID, WorklaneID) -> Void
    ) {
        self.configStore = configStore
        self.focusWorklaneHandler = focusWorklaneHandler
        super.init()
    }

    func start() {
        guard configStore.current.menuBar.showStatusItem else { return }
        guard !isStarted else {
            refresh()
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else {
            Self.logger.error("Failed to create menu bar status item button")
            NSStatusBar.system.removeStatusItem(item)
            return
        }

        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        isStarted = true
        refresh()
    }

    func stop() {
        popover?.close()
        popover = nil
        popoverViewController = nil

        for entry in subscriptions.values {
            entry.store.unsubscribe(entry.subscription)
        }
        subscriptions.removeAll()

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        isStarted = false
    }

    func syncSources(_ sources: [MenuBarWorklaneSource]) {
        self.sources = sources
        reconcileSubscriptions()
        refresh()
    }

    private func reconcileSubscriptions() {
        guard isStarted else { return }

        let sourceWindowIDs = Set(sources.map(\.windowID))
        for windowID in subscriptions.keys where !sourceWindowIDs.contains(windowID) {
            if let entry = subscriptions.removeValue(forKey: windowID) {
                entry.store.unsubscribe(entry.subscription)
            }
        }

        for source in sources {
            if let existing = subscriptions[source.windowID] {
                if existing.store !== source.worklaneStore {
                    existing.store.unsubscribe(existing.subscription)
                    subscriptions[source.windowID] = subscribe(to: source)
                }
            } else {
                subscriptions[source.windowID] = subscribe(to: source)
            }
        }
    }

    private func subscribe(
        to source: MenuBarWorklaneSource
    ) -> (store: WorklaneStore, subscription: WorklaneChangeSubscription) {
        let subscription = source.worklaneStore.subscribe { [weak self] _ in
            self?.refresh()
        }
        return (store: source.worklaneStore, subscription: subscription)
    }

    private func refresh() {
        guard isStarted else { return }

        latestSnapshots = Self.snapshots(from: sources)
        let aggregate = MenuBarStatusPresentation.aggregate(latestSnapshots.map(\.counts))
        apply(MenuBarStatusPresentation.resolve(counts: aggregate))
        popoverViewController?.update(snapshots: latestSnapshots)
        if popover?.isShown == true, let popoverViewController {
            popover?.contentSize = popoverViewController.preferredContentSize
        }
    }

    private func apply(_ presentation: MenuBarStatusPresentation) {
        guard let button = statusItem?.button else { return }

        let image = NSImage(
            systemSymbolName: presentation.symbolName,
            accessibilityDescription: presentation.accessibilityLabel
        )
        image?.isTemplate = true
        button.image = image
        button.title = presentation.title
        button.imagePosition = presentation.title.isEmpty ? .imageOnly : .imageLeft
        button.toolTip = presentation.accessibilityLabel
        button.contentTintColor = tintColor(for: presentation.tone)
    }

    private func tintColor(for tone: MenuBarStatusPresentation.Tone) -> NSColor {
        switch tone {
        case .idle:
            return .secondaryLabelColor
        case .running:
            return .labelColor
        case .waiting:
            return .systemOrange
        }
    }

    private static func snapshots(
        from sources: [MenuBarWorklaneSource]
    ) -> [MenuBarWorklaneAgentSnapshot] {
        sources.flatMap { source in
            source.worklaneStore.worklanes.enumerated().map { index, worklane in
                MenuBarWorklaneAgentSnapshot(
                    windowID: source.windowID,
                    worklaneID: worklane.id,
                    windowTitle: source.windowTitle,
                    worklaneTitle: displayTitle(for: worklane, index: index),
                    counts: counts(for: worklane)
                )
            }
        }
    }

    private static func counts(for worklane: WorklaneState) -> MenuBarAgentCounts {
        var counts = MenuBarAgentCounts.empty
        for pane in worklane.paneStripState.panes {
            guard let status = worklane.auxiliaryStateByPaneID[pane.id]?.agentStatus else {
                continue
            }
            counts.include(status.state)
        }
        return counts
    }

    private static func displayTitle(for worklane: WorklaneState, index: Int) -> String {
        if let title = worklane.meaningfulTitle {
            return title
        }
        if worklane.title.caseInsensitiveCompare("MAIN") == .orderedSame {
            return "Main"
        }
        let trimmed = worklane.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Worklane \(index + 1)" : trimmed
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        if popover?.isShown == true {
            popover?.close()
            return
        }
        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }

        let viewController = popoverViewController ?? MenuBarStatusPopoverViewController(
            onWorklaneSelected: { [weak self] windowID, worklaneID in
                self?.popover?.close()
                self?.focusWorklaneHandler(windowID, worklaneID)
            }
        )
        viewController.update(snapshots: latestSnapshots)
        popoverViewController = viewController

        let popover = self.popover ?? NSPopover()
        popover.behavior = .transient
        popover.contentViewController = viewController
        popover.contentSize = viewController.preferredContentSize
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
