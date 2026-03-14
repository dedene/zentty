import AppKit

struct PaneInsertionTransition: Equatable {
    enum Side: Equatable {
        case left
        case right
    }

    let paneID: PaneID
    let side: Side
    let initialFrame: CGRect
}

final class PaneStripView: NSView {
    var onFocusSettled: ((PaneID) -> Void)?
    var onPaneSelected: ((PaneID) -> Void)?
    var onPaneMetadataDidChange: ((PaneID, TerminalMetadata) -> Void)?

    private let motionController = PaneStripMotionController()
    private let gestureDriver = TrackpadPanGestureDriver()
    private let viewportView = NSView()
    private let adapterFactory: @MainActor () -> any TerminalAdapter

    private var currentState: PaneStripState?
    private var currentPresentation: StripPresentation?
    private var orderedPaneIDs: [PaneID] = []
    private var paneViews: [PaneID: PaneContainerView] = [:]
    private var lastRenderedSize: CGSize = .zero
    private var currentOffset: CGFloat = 0
    private var gestureBaseOffset: CGFloat = 0
    private var isInteracting = false
    private var lastFocusedPaneID: PaneID?
    private var lastInsertionTransition: PaneInsertionTransition?

    override var fittingSize: NSSize {
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        return NSSize(width: width, height: height)
    }

    override init(frame frameRect: NSRect) {
        self.adapterFactory = { TerminalAdapterRegistry.makeAdapter() }
        super.init(frame: frameRect)
        setup()
    }

    init(
        frame frameRect: NSRect = .zero,
        adapterFactory: @escaping @MainActor () -> any TerminalAdapter
    ) {
        self.adapterFactory = adapterFactory
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true

        viewportView.wantsLayer = true
        viewportView.layer?.backgroundColor = NSColor.clear.cgColor
        viewportView.layer?.masksToBounds = true
        viewportView.frame = bounds
        viewportView.autoresizingMask = [.width, .height]
        addSubview(viewportView)

        gestureDriver.onBegan = { [weak self] in
            self?.beginInteraction()
        }
        gestureDriver.onChanged = { [weak self] translationX in
            self?.updateInteraction(translationX: translationX)
        }
        gestureDriver.onEnded = { [weak self] translationX in
            self?.finishInteraction(translationX: translationX)
        }
        gestureDriver.install(on: self)
    }

    override func layout() {
        super.layout()
        viewportView.frame = bounds

        guard let currentState, bounds.size != .zero, bounds.size != lastRenderedSize else {
            return
        }

        renderCurrentState(currentState, animated: false)
    }

    func render(_ state: PaneStripState) {
        currentState = state
        guard bounds.size != .zero else {
            return
        }
        renderCurrentState(state, animated: !orderedPaneIDs.isEmpty && !isInteracting)
    }

    func focusCurrentPaneIfNeeded() {
        syncFocusedTerminal(with: currentState?.focusedPaneID, force: true)
    }

    var lastInsertionTransitionForTesting: PaneInsertionTransition? {
        lastInsertionTransition
    }

    private func renderCurrentState(_ state: PaneStripState, animated: Bool) {
        let previousPresentation = currentPresentation
        let previousOffset = currentOffset
        let presentation = motionController.presentation(for: state, in: bounds.size)
        let insertionTransition = insertionTransition(
            from: previousPresentation,
            previousOffset: previousOffset,
            to: presentation
        )
        lastInsertionTransition = insertionTransition
        currentPresentation = presentation
        let targetOffset = isInteracting ? currentOffset : presentation.targetOffset
        let shouldAnimate = animated && window?.inLiveResize != true && !inLiveResize
        reconcilePaneViews(
            with: state,
            presentation: presentation,
            initialOffset: previousOffset,
            insertionTransition: insertionTransition
        )
        orderedPaneIDs = presentation.panes.map(\.paneID)

        let updates = {
            self.applyPresentation(
                presentation,
                state: state,
                offset: targetOffset,
                animated: shouldAnimate
            )
        }

        if shouldAnimate {
            motionController.animate(in: self, updates: updates)
        } else {
            updates()
            viewportView.layoutSubtreeIfNeeded()
        }

        if !isInteracting {
            currentOffset = targetOffset
        }
        lastRenderedSize = bounds.size
        syncFocusedTerminal(with: state.focusedPaneID)
    }

    private func applyPresentation(
        _ presentation: StripPresentation,
        state: PaneStripState,
        offset: CGFloat,
        animated: Bool
    ) {
        presentation.panes.enumerated().forEach { index, panePresentation in
            guard let paneView = paneViews[panePresentation.paneID] else {
                return
            }

            let pane = state.panes[index]
            paneView.render(
                pane: pane,
                width: panePresentation.frame.width,
                height: panePresentation.frame.height,
                emphasis: panePresentation.emphasis,
                isFocused: panePresentation.isFocused
            )
            let targetFrame = panePresentation.frame.offsetBy(dx: -offset, dy: 0)
            if animated {
                paneView.animator().frame = targetFrame
            } else {
                paneView.frame = targetFrame
            }
        }
    }

    private func reconcilePaneViews(
        with state: PaneStripState,
        presentation: StripPresentation,
        initialOffset: CGFloat,
        insertionTransition: PaneInsertionTransition?
    ) {
        let nextPaneIDs = Set(presentation.panes.map(\.paneID))
        let obsoletePaneIDs = Set(paneViews.keys).subtracting(nextPaneIDs)

        for paneID in obsoletePaneIDs {
            paneViews[paneID]?.removeFromSuperview()
            paneViews.removeValue(forKey: paneID)
        }

        presentation.panes.enumerated().forEach { index, panePresentation in
            guard paneViews[panePresentation.paneID] == nil else {
                return
            }

            let pane = state.panes[index]
            let paneView = PaneContainerView(
                pane: pane,
                width: panePresentation.frame.width,
                height: panePresentation.frame.height,
                emphasis: panePresentation.emphasis,
                isFocused: panePresentation.isFocused,
                adapter: adapterFactory()
            )
            paneView.onSelected = { [weak self] in
                self?.onPaneSelected?(pane.id)
            }
            paneView.onMetadataDidChange = { [weak self] metadata in
                self?.onPaneMetadataDidChange?(pane.id, metadata)
            }
            if let insertionTransition, insertionTransition.paneID == pane.id {
                paneView.frame = insertionTransition.initialFrame
                paneView.alphaValue = 0
            } else {
                paneView.frame = panePresentation.frame.offsetBy(dx: -initialOffset, dy: 0)
            }
            paneViews[panePresentation.paneID] = paneView
            viewportView.addSubview(paneView)
        }

        lastFocusedPaneID = lastFocusedPaneID.flatMap { paneViews[$0] == nil ? nil : $0 }
    }

    private func insertionTransition(
        from previousPresentation: StripPresentation?,
        previousOffset: CGFloat,
        to nextPresentation: StripPresentation
    ) -> PaneInsertionTransition? {
        guard let previousPresentation else {
            return nil
        }

        let previousPaneIDs = Set(previousPresentation.panes.map(\.paneID))
        let nextPaneIDs = Set(nextPresentation.panes.map(\.paneID))
        let insertedPaneIDs = nextPaneIDs.subtracting(previousPaneIDs)
        let removedPaneIDs = previousPaneIDs.subtracting(nextPaneIDs)

        guard insertedPaneIDs.count == 1, removedPaneIDs.isEmpty else {
            return nil
        }

        guard
            let insertedPaneID = insertedPaneIDs.first,
            let insertedIndex = nextPresentation.panes.firstIndex(where: { $0.paneID == insertedPaneID }),
            let insertedPane = nextPresentation.panes.first(where: { $0.paneID == insertedPaneID })
        else {
            return nil
        }

        let spacing = nextPresentation.panes.count > 1
            ? nextPresentation.panes[1].frame.minX - nextPresentation.panes[0].frame.maxX
            : 16

        let previousFramesByPaneID = Dictionary(uniqueKeysWithValues: previousPresentation.panes.map { ($0.paneID, $0.frame) })

        if insertedIndex > 0 {
            let leftNeighborID = nextPresentation.panes[insertedIndex - 1].paneID
            let anchorFrame = previousFramesByPaneID[leftNeighborID] ?? insertedPane.frame
            let initialContentFrame = CGRect(
                x: anchorFrame.maxX + spacing,
                y: insertedPane.frame.minY,
                width: insertedPane.frame.width,
                height: insertedPane.frame.height
            )
            return PaneInsertionTransition(
                paneID: insertedPaneID,
                side: .right,
                initialFrame: initialContentFrame.offsetBy(dx: -previousOffset, dy: 0)
            )
        }

        if insertedIndex < nextPresentation.panes.count - 1 {
            let rightNeighborID = nextPresentation.panes[insertedIndex + 1].paneID
            let anchorFrame = previousFramesByPaneID[rightNeighborID] ?? insertedPane.frame
            let initialContentFrame = CGRect(
                x: anchorFrame.minX - spacing - insertedPane.frame.width,
                y: insertedPane.frame.minY,
                width: insertedPane.frame.width,
                height: insertedPane.frame.height
            )
            return PaneInsertionTransition(
                paneID: insertedPaneID,
                side: .left,
                initialFrame: initialContentFrame.offsetBy(dx: -previousOffset, dy: 0)
            )
        }

        return nil
    }

    private func beginInteraction() {
        guard let currentPresentation else {
            return
        }

        isInteracting = true
        gestureBaseOffset = currentPresentation.targetOffset
    }

    private func updateInteraction(translationX: CGFloat) {
        guard let currentPresentation, let currentState else {
            return
        }

        currentOffset = motionController.clampedOffset(
            gestureBaseOffset - translationX,
            contentWidth: currentPresentation.contentWidth,
            viewportWidth: bounds.width
        )
        applyPresentation(
            currentPresentation,
            state: currentState,
            offset: currentOffset,
            animated: false
        )
    }

    private func finishInteraction(translationX: CGFloat) {
        guard let currentPresentation, let currentState else {
            return
        }

        let proposedOffset = motionController.clampedOffset(
            gestureBaseOffset - translationX,
            contentWidth: currentPresentation.contentWidth,
            viewportWidth: bounds.width
        )
        let settledPaneID = motionController.nearestSettlePaneID(
            in: currentPresentation,
            proposedOffset: proposedOffset,
            viewportWidth: bounds.width
        )

        isInteracting = false

        guard let settledPaneID else {
            renderCurrentState(currentState, animated: true)
            return
        }

        if settledPaneID == currentState.focusedPaneID {
            currentOffset = currentPresentation.targetOffset
            renderCurrentState(currentState, animated: true)
            return
        }

        onFocusSettled?(settledPaneID)
    }

    private func syncFocusedTerminal(with paneID: PaneID?, force: Bool = false) {
        guard let paneID else {
            lastFocusedPaneID = nil
            return
        }

        guard force || paneID != lastFocusedPaneID else {
            return
        }

        lastFocusedPaneID = paneID
        DispatchQueue.main.async { [weak self] in
            self?.paneViews[paneID]?.focusTerminal()
        }
    }
}
