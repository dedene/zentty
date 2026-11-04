import AppKit

/// Hit-transparent view the dock previews live in: above the scrim, below
/// every float (`FloatLayerView` keeps that order).
@MainActor
final class FloatDockPreviewHostView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// Dock mode of a float drag (⌥ held): resolves the target under the cursor
/// against the live strip, draws the insertion line or split half plus the
/// "Dock here" label, runs the split dwell and the haptics. The float itself
/// keeps following the pointer; the coordinator never touches it or the
/// store. On release, `commit` hands back the target to dock into.
@MainActor
final class FloatDockCoordinator {
    typealias DwellAction = @MainActor @Sendable () -> Void
    /// Schedules `action` after the interval; returns a cancel closure.
    typealias DwellScheduler = @MainActor (TimeInterval, @escaping DwellAction) -> () -> Void

    private(set) var isActive = false
    private(set) var currentTarget: FloatDockTarget?
    /// The cursor of the last update (float-layer coordinates).
    private(set) var lastCursor: CGPoint = .zero

    private weak var previewHost: NSView?
    private let columnsProvider: () -> [ColumnPresentation]
    private let hapticFeedbackPerformer: any DragReorderHapticFeedbackPerforming
    private let scheduleDwell: DwellScheduler

    private var paneID: PaneID?
    private var hits = FloatDockHits.none
    private var dwellPaneID: PaneID?
    private var cancelDwellTimer: (() -> Void)?
    /// Once one split dwell has passed, splits resolve right away for the
    /// rest of the dock session (the tile drag behaves the same).
    private var dwellSatisfied = false
    private var geometry: FloatDockPreviewGeometry?

    private var insertionLine: PaneDragInsertionLineView?
    private var splitOverlay: PaneDragSplitOverlayView?
    private var label: FloatDockLabelView?

    init(
        previewHost: NSView,
        columnsProvider: @escaping () -> [ColumnPresentation],
        hapticFeedbackPerformer: any DragReorderHapticFeedbackPerforming = DragReorderHapticFeedbackPerformer(),
        scheduleDwell: @escaping DwellScheduler = FloatDockCoordinator.timerScheduler
    ) {
        self.previewHost = previewHost
        self.columnsProvider = columnsProvider
        self.hapticFeedbackPerformer = hapticFeedbackPerformer
        self.scheduleDwell = scheduleDwell
    }

    static func timerScheduler(_ interval: TimeInterval, _ action: @escaping DwellAction) -> () -> Void {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            MainActorShim.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    // MARK: - Session

    /// ⌥ went down during a float move (or the move started with it).
    func enter(paneID: PaneID, cursor: CGPoint) {
        if isActive {
            exit()
        }
        isActive = true
        self.paneID = paneID
        update(cursor: cursor)
    }

    /// Re-resolves the target under `cursor` and redraws the preview.
    func update(cursor: CGPoint) {
        guard isActive, let paneID else { return }
        lastCursor = cursor
        let columns = columnsProvider()
        let result = resolve(cursor: cursor, columns: columns, paneID: paneID)
        hits = result.hits
        if let pending = result.pendingSplit {
            startDwell(for: pending.targetPaneID)
        } else if result.hits.split == nil {
            cancelDwell()
        }

        let previousTarget = currentTarget
        currentTarget = result.target
        if let target = currentTarget, target != previousTarget {
            performHaptic(for: target)
        }
        let canvas = previewHost?.bounds ?? .zero
        showPreview(currentTarget.flatMap {
            FloatDockResolver.previewGeometry(for: $0, columns: columns, canvas: canvas)
        })
    }

    /// The strip changed under a live dock drag (a re-render). The shown
    /// target keeps its place if it still exists; if it went away (its pane
    /// closed) the preview clears and nothing is targeted until the pointer
    /// moves again, so a release never docks somewhere it didn't show.
    func stripDidChange() {
        guard isActive, let target = currentTarget else { return }
        let canvas = previewHost?.bounds ?? .zero
        guard let geometry = FloatDockResolver.previewGeometry(
            for: target,
            columns: columnsProvider(),
            canvas: canvas
        ) else {
            currentTarget = nil
            hits = .none
            showPreview(nil)
            return
        }
        showPreview(geometry)
    }

    /// ⌥ released mid-drag: the previews go, the plain move continues.
    func exit() {
        guard isActive else { return }
        isActive = false
        paneID = nil
        hits = .none
        currentTarget = nil
        dwellSatisfied = false
        cancelDwell()
        tearDownPreviews()
    }

    /// Release in dock mode. Re-resolves against fresh columns (the strip may
    /// have changed under the drag) and returns the target only when it is
    /// still the one the preview showed; nil leaves the float where it was
    /// dropped. Ends the dock session either way.
    func commit(cursor: CGPoint) -> FloatDockTarget? {
        guard isActive, let paneID else { return nil }
        let result = resolve(cursor: cursor, columns: columnsProvider(), paneID: paneID)
        let shown = currentTarget
        exit()
        guard let target = result.target, target == shown else {
            return nil
        }
        return target
    }

    func cancel() {
        exit()
    }

    var previewForTesting: (geometry: FloatDockPreviewGeometry?, labelText: String?) {
        (geometry, label.map(\.text))
    }

    var labelViewForTesting: FloatDockLabelView? {
        label
    }

    // MARK: - Resolution

    private func resolve(cursor: CGPoint, columns: [ColumnPresentation], paneID: PaneID) -> FloatDockResolver.Result {
        FloatDockResolver.resolve(FloatDockResolver.Input(
            cursor: cursor,
            canvas: previewHost?.bounds ?? .zero,
            columns: columns,
            draggedPaneID: paneID,
            previous: hits,
            splitDwellSatisfied: dwellSatisfied
        ))
    }

    private func startDwell(for targetPaneID: PaneID) {
        guard dwellPaneID != targetPaneID else { return }
        cancelDwell()
        dwellPaneID = targetPaneID
        cancelDwellTimer = scheduleDwell(FloatDockResolver.splitDwellDuration) { [weak self] in
            guard let self, self.isActive, self.dwellPaneID == targetPaneID else { return }
            self.dwellSatisfied = true
            self.update(cursor: self.lastCursor)
        }
    }

    private func cancelDwell() {
        cancelDwellTimer?()
        cancelDwellTimer = nil
        dwellPaneID = nil
    }

    private func performHaptic(for target: FloatDockTarget) {
        switch target {
        case .columnGap, .stackGap:
            hapticFeedbackPerformer.performReorderAlignmentFeedback()
        case .split:
            hapticFeedbackPerformer.performStructuralChangeFeedback()
        case .origin:
            break
        }
    }

    // MARK: - Previews

    private func showPreview(_ geometry: FloatDockPreviewGeometry?) {
        guard geometry != self.geometry else { return }
        self.geometry = geometry
        guard let previewHost else { return }

        switch geometry {
        case .columnLine(let frame), .stackLine(let frame):
            removeSplitOverlay()
            let line = insertionLine ?? makeInsertionLine(in: previewHost)
            if case .columnLine = geometry {
                line.setOrientation(.vertical)
            } else {
                line.setOrientation(.horizontal)
            }
            line.isHidden = false
            line.frame = frame
            line.startPulsing()
        case .splitHalf(let frame), .emptyStrip(let frame):
            insertionLine?.isHidden = true
            if let splitOverlay {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = FloatMotion.reduceMotion ? 0 : 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    context.allowsImplicitAnimation = true
                    splitOverlay.frame = frame
                }
            } else {
                let overlay = PaneDragSplitOverlayView(frame: frame)
                addBelowLabel(overlay, in: previewHost)
                splitOverlay = overlay
                overlay.animateIn()
            }
        case nil:
            insertionLine?.isHidden = true
            removeSplitOverlay()
        }

        guard let geometry else {
            label?.removeFromSuperview()
            label = nil
            return
        }
        let label = self.label ?? {
            let view = FloatDockLabelView(frame: .zero)
            previewHost.addSubview(view)
            self.label = view
            return view
        }()
        let frame = geometry.frame
        label.center(on: CGPoint(x: frame.midX, y: frame.midY), within: previewHost.bounds)
    }

    private func makeInsertionLine(in host: NSView) -> PaneDragInsertionLineView {
        let line = PaneDragInsertionLineView(frame: .zero)
        addBelowLabel(line, in: host)
        insertionLine = line
        return line
    }

    private func addBelowLabel(_ view: NSView, in host: NSView) {
        if let label, label.superview === host {
            host.addSubview(view, positioned: .below, relativeTo: label)
        } else {
            host.addSubview(view)
        }
    }

    private func removeSplitOverlay() {
        splitOverlay?.removeFromSuperview()
        splitOverlay = nil
    }

    private func tearDownPreviews() {
        geometry = nil
        insertionLine?.stopPulsing()
        insertionLine?.removeFromSuperview()
        insertionLine = nil
        removeSplitOverlay()
        label?.removeFromSuperview()
        label = nil
    }
}
