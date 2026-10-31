import AppKit
import os

/// What the float layer draws for the active worklane.
struct FloatLayerContent: Equatable {
    var floats: [FloatingPaneState]
    var floatsHidden: Bool
    /// The float that owns keyboard focus (`WorklaneState.floatOwnsFocus`), else nil.
    var focusedFloatID: PaneID?
    var borderContextByPaneID: [PaneID: PaneBorderContextDisplayModel]
    var worklaneColor: WorklaneColor?

    static let empty = FloatLayerContent(
        floats: [],
        floatsHidden: false,
        focusedFloatID: nil,
        borderContextByPaneID: [:],
        worklaneColor: nil
    )

    init(
        floats: [FloatingPaneState],
        floatsHidden: Bool,
        focusedFloatID: PaneID?,
        borderContextByPaneID: [PaneID: PaneBorderContextDisplayModel] = [:],
        worklaneColor: WorklaneColor? = nil
    ) {
        self.floats = floats
        self.floatsHidden = floatsHidden
        self.focusedFloatID = focusedFloatID
        self.borderContextByPaneID = borderContextByPaneID
        self.worklaneColor = worklaneColor
    }

    init(
        worklane: WorklaneState,
        borderContextByPaneID: [PaneID: PaneBorderContextDisplayModel] = [:]
    ) {
        self.init(
            floats: worklane.floatingPanes,
            floatsHidden: worklane.floatsHidden,
            focusedFloatID: worklane.floatOwnsFocus ? worklane.focusedFloatID : nil,
            borderContextByPaneID: Self.floatBorderContexts(worklane: worklane, base: borderContextByPaneID),
            worklaneColor: worklane.color
        )
    }

    /// Border legends for the worklane's floats, each with its bold name
    /// (`name · cwd`). When the base label already is the name (a custom
    /// title), the cwd takes its place so the name isn't shown twice.
    private static func floatBorderContexts(
        worklane: WorklaneState,
        base: [PaneID: PaneBorderContextDisplayModel]
    ) -> [PaneID: PaneBorderContextDisplayModel] {
        var result = base.filter { worklane.isFloating($0.key) }
        for float in worklane.floatingPanes {
            let paneID = float.pane.id
            let auxiliaryState = worklane.auxiliaryStateByPaneID[paneID]
            guard let name = FloatDisplayName.resolve(
                pane: float.pane,
                presentation: auxiliaryState?.presentation,
                metadata: auxiliaryState?.metadata
            ) else {
                continue
            }
            var model = result[paneID] ?? PaneBorderContextDisplayModel(text: "")
            if model.text == name {
                var replacement = PaneBorderContextDisplayModel(
                    text: auxiliaryState?.shellContext?.borderContextDisplayText ?? ""
                )
                replacement.isAgentTeamLeader = model.isAgentTeamLeader
                replacement.isAgentTeamMember = model.isAgentTeamMember
                model = replacement
            }
            model.displayName = name
            result[paneID] = model
        }
        return result
    }

    var ownsFocus: Bool {
        focusedFloatID != nil
    }
}

/// Hit-transparent layer above the pane strip that hosts the active
/// worklane's floats and PiPs. Each float is a real `PaneContainerView` on
/// the shared runtime registry: mounting it borrows the pane's existing host
/// view (the same surface the strip used), it never creates a new one.
@MainActor
final class FloatLayerView: NSView {
    private static let logger = Logger(subsystem: "be.zenjoy.zentty", category: "FloatLayer")
    private static let maxFocusAttempts = 20

    var onFloatSelected: ((PaneID) -> Void)?
    var onFloatCloseRequested: ((PaneID) -> Void)?
    var onPipClicked: ((PaneID) -> Void)?
    var onFloatActionRequested: ((PaneID, PaneBorderAction) -> Void)?
    var shouldSuppressProgrammaticTerminalFocus: (() -> Bool)?
    /// Wires a new float container like a strip pane (providers, copy path).
    /// Runs once per container, right after it is created.
    var containerConfigurator: ((PaneContainerView, PaneID) -> Void)?

    private let runtimeRegistry: PaneRuntimeRegistry
    private var containers: [PaneID: PaneContainerView] = [:]
    private var pipHosts: [PaneID: PipContainerView] = [:]
    private var floatHosts: [PaneID: FloatContainerView] = [:]
    private var shortcutManager: ShortcutManager?
    private var content = FloatLayerContent.empty
    private var currentTheme = ZenttyTheme.fallback(for: nil)
    private var showPaneBorders = AppConfig.Panes.default.showBorders
    private var smoothScrollingEnabled = AppConfig.Panes.default.smoothScrollingEnabled
    private var lastFocusedFloatID: PaneID?
    private var focusGeneration: UInt64 = 0

    init(runtimeRegistry: PaneRuntimeRegistry) {
        self.runtimeRegistry = runtimeRegistry
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        applyPlacements(duringLayout: true)
    }

    // MARK: - Render

    func render(
        _ content: FloatLayerContent,
        theme: ZenttyTheme,
        showPaneBorders: Bool,
        smoothScrollingEnabled: Bool
    ) {
        self.content = content
        let themeChanged = theme != currentTheme
        currentTheme = theme
        self.showPaneBorders = showPaneBorders
        self.smoothScrollingEnabled = smoothScrollingEnabled
        if themeChanged {
            containers.values.forEach { $0.apply(theme: theme, animated: false) }
        }
        applyPlacements(duringLayout: false)
        syncFocus(force: false)
    }

    func updateShortcutTooltips(_ shortcutManager: ShortcutManager) {
        self.shortcutManager = shortcutManager
        containers.values.forEach { $0.updateShortcutTooltips(shortcutManager) }
    }

    /// Gives keyboard focus to the float that owns it. Returns false when no
    /// float owns focus (the strip should take it instead).
    @discardableResult
    func focusOwningFloatIfNeeded() -> Bool {
        guard content.ownsFocus else {
            return false
        }
        syncFocus(force: true)
        return true
    }

    // MARK: - Placement

    private func applyPlacements(duringLayout: Bool) {
        let placements = FloatLayerLayout.placements(
            floats: content.floats,
            floatsHidden: content.floatsHidden,
            canvas: bounds
        )
        let floatsByID = Dictionary(
            content.floats.map { ($0.pane.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let mountedIDs = Set(placements.map(\.paneID))

        for paneID in Set(containers.keys).subtracting(mountedIDs) {
            unmount(paneID)
        }

        var newlyMounted: [PaneContainerView] = []
        for placement in placements {
            guard let float = floatsByID[placement.paneID] else { continue }
            let (container, isNew) = container(for: float, size: placement.contentSize)
            if isNew {
                newlyMounted.append(container)
            }
            switch placement.kind {
            case .floating:
                container.chromeKind = .float
                mountFloating(container, paneID: placement.paneID, frame: placement.frame)
            case .pip(let contentSize):
                container.chromeKind = .pip
                mountPip(container, paneID: placement.paneID, frame: placement.frame, contentSize: contentSize)
            }
            container.render(
                pane: float.pane,
                emphasis: 1,
                isFocused: content.focusedFloatID == placement.paneID,
                borderContext: content.borderContextByPaneID[placement.paneID],
                worklaneColor: content.worklaneColor,
                animated: false
            )
        }

        sortMountedViews(by: placements.map(\.paneID))

        if !newlyMounted.isEmpty {
            if !duringLayout {
                layoutSubtreeIfNeeded()
            }
            // Viewport suspension lives on the shared surface, not on the
            // container: a surface the strip (animated render) or an earlier
            // PiP left suspended stays frozen at its old grid until someone
            // clears it. A new `.floating` container is the sole owner now, so
            // clear it here. PiP containers (under a PipContainerView) keep it.
            for container in newlyMounted where container.superview is FloatContainerView {
                container.setTerminalViewportSyncSuspended(false)
                container.forceTerminalViewportSync()
            }
        }
    }

    private func container(for float: FloatingPaneState, size: CGSize) -> (PaneContainerView, Bool) {
        if let existing = containers[float.pane.id] {
            existing.showPaneBorders = showPaneBorders
            if existing.smoothScrollingEnabled != smoothScrollingEnabled {
                existing.smoothScrollingEnabled = smoothScrollingEnabled
            }
            return (existing, false)
        }

        let paneID = float.pane.id
        let isPip: Bool
        if case .pip = float.mode { isPip = true } else { isPip = false }
        let container = PaneContainerView(
            pane: float.pane,
            width: max(1, size.width),
            height: max(1, size.height),
            emphasis: 1,
            isFocused: content.focusedFloatID == paneID,
            runtime: runtimeRegistry.runtime(for: float.pane),
            theme: currentTheme,
            initialViewportSyncSuspended: isPip
        )
        container.showPaneBorders = showPaneBorders
        container.smoothScrollingEnabled = smoothScrollingEnabled
        container.onSelected = { [weak self] in
            self?.onFloatSelected?(paneID)
        }
        container.onCloseRequested = { [weak self] in
            self?.onFloatCloseRequested?(paneID)
        }
        container.onBorderActionRequested = { [weak self] action in
            self?.onFloatActionRequested?(paneID, action)
        }
        if let shortcutManager {
            container.updateShortcutTooltips(shortcutManager)
        }
        containerConfigurator?(container, paneID)
        containers[paneID] = container
        container.activateSessionIfNeeded()
        return (container, true)
    }

    private func mountFloating(_ container: PaneContainerView, paneID: PaneID, frame: CGRect) {
        let host = floatHost(for: paneID)
        host.setPaneFrame(frame)
        if let pip = pipHosts.removeValue(forKey: paneID) {
            // Leave PiP: re-parent at the final unscaled frame, then resume
            // viewport sync, so the grid never sees the scaled size.
            host.host(container)
            pip.removeFromSuperview()
            container.setTerminalViewportSyncSuspended(false)
            return
        }
        if container.superview !== host {
            host.host(container)
        }
    }

    private func floatHost(for paneID: PaneID) -> FloatContainerView {
        if let existing = floatHosts[paneID] {
            return existing
        }
        let host = FloatContainerView(paneID: paneID)
        floatHosts[paneID] = host
        addSubview(host)
        return host
    }

    private func mountPip(_ container: PaneContainerView, paneID: PaneID, frame: CGRect, contentSize: CGSize) {
        let pip: PipContainerView
        if let existing = pipHosts[paneID] {
            pip = existing
        } else {
            pip = PipContainerView(paneID: paneID)
            pip.onClicked = { [weak self] id in
                self?.onPipClicked?(id)
            }
            pipHosts[paneID] = pip
            addSubview(pip)
        }
        if container.superview !== pip {
            // Enter PiP: freeze the grid before the container is scaled.
            container.setTerminalViewportSyncSuspended(true)
            container.removeFromSuperview()
            container.frame = CGRect(origin: .zero, size: contentSize)
            pip.addSubview(container)
        }
        floatHosts.removeValue(forKey: paneID)?.removeFromSuperview()
        pip.apply(frame: frame, contentSize: contentSize)
    }

    private func unmount(_ paneID: PaneID) {
        guard let container = containers.removeValue(forKey: paneID) else { return }
        container.prepareForRemoval()
        container.removeFromSuperview()
        pipHosts.removeValue(forKey: paneID)?.removeFromSuperview()
        floatHosts.removeValue(forKey: paneID)?.removeFromSuperview()
        if lastFocusedFloatID == paneID {
            lastFocusedFloatID = nil
        }
    }

    /// Reorders mounted views back to front without removing them (removal
    /// would make a focused terminal resign first responder).
    private func sortMountedViews(by order: [PaneID]) {
        let rankByView = Dictionary(
            uniqueKeysWithValues: order.enumerated().compactMap { index, paneID -> (ObjectIdentifier, Int)? in
                guard let view: NSView = pipHosts[paneID] ?? floatHosts[paneID] else { return nil }
                return (ObjectIdentifier(view), index)
            }
        )
        let current = subviews.compactMap { rankByView[ObjectIdentifier($0)] }
        guard current != current.sorted() else { return }

        let box = Unmanaged.passRetained(RankBox(rankByView))
        defer { box.release() }
        sortSubviews({ lhs, rhs, context in
            guard let context else { return .orderedSame }
            let ranks = Unmanaged<RankBox>.fromOpaque(context).takeUnretainedValue().ranks
            let left = ranks[ObjectIdentifier(lhs)] ?? -1
            let right = ranks[ObjectIdentifier(rhs)] ?? -1
            return left < right ? .orderedAscending : (left > right ? .orderedDescending : .orderedSame)
        }, context: box.toOpaque())
    }

    // MARK: - Focus

    private func syncFocus(force: Bool) {
        let focusedID = content.focusedFloatID
        defer { lastFocusedFloatID = focusedID }
        guard let focusedID else {
            focusGeneration &+= 1
            return
        }
        guard force || focusedID != lastFocusedFloatID else {
            return
        }
        focusGeneration &+= 1
        attemptFocus(paneID: focusedID, generation: focusGeneration, attempt: 0)
    }

    private func attemptFocus(paneID: PaneID, generation: UInt64, attempt: Int) {
        guard generation == focusGeneration, content.focusedFloatID == paneID else {
            return
        }
        if shouldSuppressProgrammaticTerminalFocus?() == true {
            return
        }
        if let container = containers[paneID], container.superview is FloatContainerView,
           container.focusTerminalIfReady() {
            return
        }
        guard attempt < Self.maxFocusAttempts else {
            Self.logger.info("float focus gave up for \(paneID.rawValue, privacy: .public)")
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.attemptFocus(paneID: paneID, generation: generation, attempt: attempt + 1)
        }
    }

    // MARK: - Testing

    func containerForTesting(_ paneID: PaneID) -> PaneContainerView? {
        containers[paneID]
    }

    func pipHostForTesting(_ paneID: PaneID) -> PipContainerView? {
        pipHosts[paneID]
    }

    func floatHostForTesting(_ paneID: PaneID) -> FloatContainerView? {
        floatHosts[paneID]
    }
}

private final class RankBox {
    let ranks: [ObjectIdentifier: Int]

    init(_ ranks: [ObjectIdentifier: Int]) {
        self.ranks = ranks
    }
}

private extension FloatLayerPlacement {
    /// Size the float's content is laid out at (the float frame, or the
    /// unscaled float size for a PiP).
    var contentSize: CGSize {
        switch kind {
        case .floating:
            frame.size
        case .pip(let contentSize):
            contentSize
        }
    }
}
