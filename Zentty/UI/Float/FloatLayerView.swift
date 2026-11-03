import AppKit
import os

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
    /// A dragged or swiped PiP asks for a corner (see +PipGestures).
    var onPipMoveRequested: ((PaneID, FloatCorner) -> Void)?
    /// The user dragged, flicked or bounced a PiP (wherever it ends up), so
    /// an auto-popped PiP stays put once its agent moves on.
    var onPipTouched: ((PaneID) -> Void)?
    var onFloatActionRequested: ((PaneID, PaneBorderAction) -> Void)?
    /// A move/resize/throw gesture ended; the canvas is the layer's bounds
    /// (normalize the frames against it). `.click` needs no store change.
    var onFloatGestureEnded: ((PaneID, FloatGestureOutcome, CGRect) -> Void)?
    /// A float or PiP moved or the set changed (see +MouseOcclusion).
    var onOccludingFramesChanged: (() -> Void)?
    var shouldSuppressProgrammaticTerminalFocus: (() -> Bool)?
    /// Wires a new float container like a strip pane (providers, copy path).
    /// Runs once per container, right after it is created.
    var containerConfigurator: ((PaneContainerView, PaneID) -> Void)?

    private let runtimeRegistry: PaneRuntimeRegistry
    var containers: [PaneID: PaneContainerView] = [:]
    var pipHosts: [PaneID: PipContainerView] = [:]
    var floatHosts: [PaneID: FloatContainerView] = [:]
    /// Back-most subview: dims the strip while a float has focus.
    private let scrimView = FloatScrimView()
    /// Dock previews: above the scrim, below every float.
    let dockPreviewView = FloatDockPreviewHostView()
    /// The strip's columns in this layer's coordinates (dock targeting).
    var dockColumnsProvider: (() -> [ColumnPresentation])?
    lazy var dockCoordinator = FloatDockCoordinator(
        previewHost: dockPreviewView,
        columnsProvider: { [weak self] in self?.dockColumnsProvider?() ?? [] }
    )
    private(set) var shortcutManager: ShortcutManager?
    private(set) var content = FloatLayerContent.empty
    private(set) var currentTheme = ZenttyTheme.fallback(for: nil)
    private var showPaneBorders = AppConfig.Panes.default.showBorders
    private var smoothScrollingEnabled = AppConfig.Panes.default.smoothScrollingEnabled
    private var lastFocusedFloatID: PaneID?
    /// Room at the bottom the PiPs keep clear (the pill bar while it shows).
    var bottomInset: CGFloat = 0
    /// PiP width (`floats.pip_size`). A change re-places mounted PiPs right
    /// away; they move to their new slot like a restack.
    var pipWidth: CGFloat = FloatLayout.pipSmallWidth {
        didSet {
            guard pipWidth != oldValue, !pipHosts.isEmpty else { return }
            applyPlacements(duringLayout: false)
        }
    }
    private var focusGeneration: UInt64 = 0
    /// Frames of floats under a live gesture. They win over the store until
    /// the gesture ends, so a re-render mid-drag (agent status, the raise on
    /// mouse-down) can't snap the float back.
    var interactiveFrames: [PaneID: CGRect] = [:]
    /// Tile frames of panes about to float in place (`prepareLift`).
    var pendingLiftSources: [PaneID: CGRect] = [:]
    /// PiPs about to mount and where they enter from (see +Pip).
    var pendingPipEntries: [PaneID: PipEntry] = [:]
    /// Each mounted PiP's slot from the last placement: where a drag or a
    /// swipe settles when the store keeps it in its corner.
    var pipRestingFrames: [PaneID: CGRect] = [:]
    /// A PiP gesture settled (pane, the corner it asked for).
    var onPipSettledForTesting: ((PaneID, FloatCorner) -> Void)?
    var onLiftInPlaceFinishedForTesting: ((PaneID) -> Void)?
    /// A PiP entered (PiP pane, from frame) or left (float pane, from frame)
    /// with motion.
    var onPipMotionForTesting: ((PaneID, CGRect) -> Void)?
    /// Mode-change motion for the next render (see +Transitions).
    var pendingDepartures: [PaneID: FloatDeparture] = [:]
    var pendingEntries: [PaneID: FloatEntry] = [:]
    /// Floats and PiPs drawing their way out, by pane.
    var departingViews: [PaneID: NSView] = [:]
    var onDepartureForTesting: ((PaneID, FloatDeparture) -> Void)?
    var onEntryForTesting: ((PaneID, FloatEntry) -> Void)?

    init(runtimeRegistry: PaneRuntimeRegistry) {
        self.runtimeRegistry = runtimeRegistry
        super.init(frame: .zero)
        wantsLayer = true
        // Ranked below every float in `sortMountedViews`.
        addSubview(scrimView, positioned: .below, relativeTo: nil)
        addSubview(dockPreviewView, positioned: .above, relativeTo: scrimView)
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
        scrimView.frame = bounds
        dockPreviewView.frame = bounds
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
        scrimView.frame = bounds
        dockPreviewView.frame = bounds
        scrimView.setVisible(FloatScrimPolicy.isVisible(content), animated: window != nil)
        applyPlacements(duringLayout: false)
        syncFocus(force: false)
        // Strip renders reach the layer right after the strip: keep a live
        // dock preview on its (possibly moved or gone) target.
        dockCoordinator.stripDidChange()
    }

    func updateShortcutTooltips(_ shortcutManager: ShortcutManager) {
        self.shortcutManager = shortcutManager
        containers.values.forEach { $0.updateShortcutTooltips(shortcutManager) }
        pipHosts.values.forEach { $0.updateShortcutTooltips(shortcutManager) }
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
            canvas: bounds,
            pipWidth: pipWidth,
            bottomInset: bottomInset
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
        var liftsInPlace: [(paneID: PaneID, container: PaneContainerView, frame: CGRect)] = []
        var entries: [(PaneID, FloatEntry)] = []
        for placement in placements {
            guard let float = floatsByID[placement.paneID] else { continue }
            let (container, isNew) = container(for: float, size: placement.contentSize)
            if isNew {
                newlyMounted.append(container)
                if !duringLayout, pendingLiftSources[placement.paneID] == nil,
                   let entry = pendingEntries[placement.paneID] {
                    if case .fromFrame(let pillFrame) = entry, case .pip = placement.kind {
                        pendingPipEntries[placement.paneID] = PipEntry(
                            fromFrame: pillFrame,
                            velocity: .zero,
                            fadesIn: true
                        )
                    } else {
                        entries.append((placement.paneID, entry))
                    }
                }
            }
            switch placement.kind {
            case .floating:
                container.chromeKind = .float
                if isNew, !duringLayout, let tileFrame = pendingLiftSources[placement.paneID] {
                    liftsInPlace.append((placement.paneID, container, placement.frame))
                    // Held like a gesture frame so the layout pass below
                    // keeps the tile slot until the lift animation starts.
                    interactiveFrames[placement.paneID] = tileFrame
                    mountFloating(container, paneID: placement.paneID, frame: tileFrame)
                } else {
                    // A PiP's drag frame never carries over to the float.
                    let leavesPip = pipHosts[placement.paneID] != nil
                    mountFloating(
                        container,
                        paneID: placement.paneID,
                        frame: leavesPip ? placement.frame : interactiveFrames[placement.paneID] ?? placement.frame
                    )
                }
            case .pip(let contentSize):
                container.chromeKind = .pip
                mountPip(
                    container,
                    paneID: placement.paneID,
                    frame: placement.frame,
                    contentSize: contentSize,
                    isNew: isNew,
                    animatesMoves: !duringLayout
                )
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
        updateFloatMouseOcclusion()
        if !duringLayout {
            pendingLiftSources.removeAll()
            pendingPipEntries.removeAll()
            pendingDepartures.removeAll()
            pendingEntries.removeAll()
        }

        if !newlyMounted.isEmpty {
            if !duringLayout {
                layoutSubtreeIfNeeded()
            }
            // Viewport suspension lives on the shared surface, not on the
            // container: a surface the strip (animated render) or an earlier
            // PiP left suspended stays frozen at its old grid until someone
            // clears it. A new `.floating` container is the sole owner now, so
            // clear it here. PiP containers (under a PipContainerView) keep it.
            // A float lifting in place keeps the tile's grid until its
            // animation lands (`animateLiftInPlace`).
            let liftingContainers = Set(liftsInPlace.map { ObjectIdentifier($0.container) })
            for container in newlyMounted where container.superview is FloatContainerView
                && !liftingContainers.contains(ObjectIdentifier(container)) {
                container.setTerminalViewportSyncSuspended(false)
                container.forceTerminalViewportSync()
            }
        }
        for lift in liftsInPlace {
            animateLiftInPlace(paneID: lift.paneID, container: lift.container, to: lift.frame)
        }
        for (paneID, entry) in entries {
            animateEntry(paneID, entry: entry)
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
        // Its leaving copy still holds the terminal: let it go first.
        finishDeparture(paneID)
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
            initialViewportSyncSuspended: isPip,
            initialViewportSuspensionOwner: .pip
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
            pipRestingFrames.removeValue(forKey: paneID)
            interactiveFrames.removeValue(forKey: paneID)
            pip.cancelDrag()
            let pipFrame = pip.frame
            host.host(container)
            pip.removeFromSuperview()
            pip.relinquishHostedContainer()
            animateRestore(host, fromPipFrame: pipFrame)
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
        wireGestures(of: host)
        floatHosts[paneID] = host
        addSubview(host)
        return host
    }

    private func unmount(_ paneID: PaneID) {
        guard let container = containers.removeValue(forKey: paneID) else { return }
        // A live gesture ends here, uncommitted; its lift is undone before
        // the container leaves.
        floatHosts[paneID]?.cancelGesture()
        interactiveFrames.removeValue(forKey: paneID)
        container.prepareForRemoval()
        let pip = pipHosts.removeValue(forKey: paneID)
        pip?.cancelDrag()
        let host = floatHosts.removeValue(forKey: paneID)
        pipRestingFrames.removeValue(forKey: paneID)
        if let departure = pendingDepartures[paneID], let leaving: NSView = pip ?? host {
            // Draws its way out with its terminal still inside (+Transitions).
            beginDeparture(leaving, paneID: paneID, departure: departure, paneFrame: pip == nil ? host?.paneFrame : nil)
        } else {
            container.removeFromSuperview()
            pip?.removeFromSuperview()
            host?.removeFromSuperview()
        }
        if lastFocusedFloatID == paneID {
            lastFocusedFloatID = nil
        }
    }

    /// Reorders mounted views back to front without removing them (removal
    /// would make a focused terminal resign first responder).
    private func sortMountedViews(by order: [PaneID]) {
        var rankByView = Dictionary(
            uniqueKeysWithValues: order.enumerated().compactMap { index, paneID -> (ObjectIdentifier, Int)? in
                guard let view: NSView = pipHosts[paneID] ?? floatHosts[paneID] else { return nil }
                return (ObjectIdentifier(view), index)
            }
        )
        rankByView[ObjectIdentifier(scrimView)] = -2
        rankByView[ObjectIdentifier(dockPreviewView)] = -1
        // Leaving copies stay in front until they are gone.
        for (index, view) in departingViews.values.enumerated() {
            rankByView[ObjectIdentifier(view)] = order.count + index
        }
        let current = subviews.compactMap { rankByView[ObjectIdentifier($0)] }
        guard current != current.sorted() else { return }

        let box = Unmanaged.passRetained(RankBox(rankByView))
        defer { box.release() }
        sortSubviews({ lhs, rhs, context in
            guard let context else { return .orderedSame }
            let ranks = Unmanaged<RankBox>.fromOpaque(context).takeUnretainedValue().ranks
            let left = ranks[ObjectIdentifier(lhs)] ?? -3
            let right = ranks[ObjectIdentifier(rhs)] ?? -3
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

    var scrimViewForTesting: FloatScrimView {
        scrimView
    }

    func containerForTesting(_ paneID: PaneID) -> PaneContainerView? {
        containers[paneID]
    }

    func pipHostForTesting(_ paneID: PaneID) -> PipContainerView? {
        pipHosts[paneID]
    }

    func floatHostForTesting(_ paneID: PaneID) -> FloatContainerView? {
        floatHosts[paneID]
    }

    func interactiveFrameForTesting(_ id: PaneID) -> CGRect? {
        interactiveFrames[id]
    }

    // MARK: - Interaction support (see +Interaction)

    /// A move/resize/throw press is in progress on some float or PiP.
    var isGestureActive: Bool {
        floatHosts.values.contains { $0.activeGesture != nil }
            || pipHosts.values.contains { $0.drag != nil }
    }

    func floatHost(_ paneID: PaneID) -> FloatContainerView? {
        floatHosts[paneID]
    }

    func mountedContainer(_ paneID: PaneID) -> PaneContainerView? {
        containers[paneID]
    }

    /// Model frames of mounted floats (pane rect) and PiPs, in `view`'s
    /// coordinates: where the strip underneath must ignore the pointer.
    func occludingFrames(in view: NSView) -> [CGRect] {
        let hosts: [CGRect] = floatHosts.values.map(\.paneFrame) + pipHosts.values.map(\.frame)
        return hosts.map { view.convert($0, from: self) }
    }

    /// The store's frame for a mounted `.floating` float.
    func storeFrame(for paneID: PaneID) -> CGRect? {
        guard let float = content.floats.first(where: { $0.pane.id == paneID }), float.mode.isFloating else {
            return nil
        }
        return FloatLayerLayout.floatFrame(for: float, canvas: bounds)
    }
}

private final class RankBox {
    let ranks: [ObjectIdentifier: Int]

    init(_ ranks: [ObjectIdentifier: Int]) {
        self.ranks = ranks
    }
}
