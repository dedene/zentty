import AppKit
import XCTest
@testable import Zentty

/// Detached float layer and PiPs: the spike 0a order, the unscaled prime of
/// a fresh PiP container, the corner spring in and out, status strips.
@MainActor
final class FloatLayerViewPipTests: AppKitTestCase {
    private let floatID = PaneID("float")
    private let canvas = CGRect(x: 0, y: 0, width: 1000, height: 700)
    private let floatFrame = NormalizedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
    private var adapters: [PaneID: PipViewportSpyAdapter] = [:]
    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        FloatMotion.reduceMotionOverride = false
    }

    override func tearDown() {
        FloatMotion.reduceMotionOverride = nil
        window?.close()
        window = nil
        adapters = [:]
        super.tearDown()
    }

    // MARK: - Mount order

    func test_fresh_pip_container_is_primed_unscaled_at_the_float_size() throws {
        let layer = makeLayer(inWindow: true)

        layer.render(content(mode: .pip(corner: .bottomRight, order: 0)))

        let view = try XCTUnwrap(adapters[floatID]?.view)
        let floatSize = CGSize(width: 600, height: 350)
        let primeIndex = try XCTUnwrap(
            view.log.firstIndex { !$0.suspended && !$0.wasInPip },
            "the fresh container syncs once before it is scaled"
        )
        XCTAssertEqual(view.log[primeIndex].containerSize, floatSize)
        XCTAssertTrue(view.forcedSyncs.contains { !$0.wasInPip && $0.containerSize == floatSize })
        let pipSuspendIndex = try XCTUnwrap(view.log.lastIndex { $0.suspended })
        XCTAssertGreaterThan(pipSuspendIndex, primeIndex, "suspended again before the scale")
        XCTAssertFalse(view.log[pipSuspendIndex].wasInPip, "suspend happens before the re-parent")
        XCTAssertFalse(view.log.contains { !$0.suspended && $0.wasInPip }, "never resumed while scaled")
        XCTAssertFalse(view.forcedSyncs.contains { $0.wasInPip }, "never forced while scaled")
        XCTAssertEqual(view.isSuspended, true)
        let pip = try XCTUnwrap(layer.pipHostForTesting(floatID))
        XCTAssertEqual(pip.scaleViewForTesting.bounds.size, floatSize)
        XCTAssertTrue(view.isDescendant(of: pip))
    }

    func test_pip_from_a_live_float_is_not_primed_again() throws {
        let layer = makeLayer(inWindow: true)
        layer.render(content(mode: .floating))
        let view = try XCTUnwrap(adapters[floatID]?.view)
        view.log.removeAll()

        layer.render(content(mode: .pip(corner: .bottomRight, order: 0)))

        XCTAssertEqual(view.log.map(\.suspended), [true], "one suspend, no resume")
        XCTAssertFalse(view.log[0].wasInPip)
    }

    func test_detached_layer_skips_the_prime() throws {
        let layer = makeLayer(inWindow: false)

        layer.render(content(mode: .pip(corner: .bottomRight, order: 0)))

        let view = try XCTUnwrap(adapters[floatID]?.view)
        XCTAssertFalse(view.log.contains { !$0.suspended }, "no backing scale to sync against without a window")
        XCTAssertEqual(view.isSuspended, true)
    }

    // MARK: - Motion

    func test_float_to_pip_springs_from_the_float_frame() throws {
        let layer = makeLayer(inWindow: false)
        layer.render(content(mode: .floating))
        let floatPaneFrame = try XCTUnwrap(layer.floatHostForTesting(floatID)?.paneFrame)
        var motions: [(PaneID, CGRect)] = []
        layer.onPipMotionForTesting = { motions.append(($0, $1)) }

        layer.render(content(mode: .pip(corner: .bottomRight, order: 0)))

        XCTAssertEqual(motions.map(\.0), [floatID])
        XCTAssertEqual(motions.first?.1, floatPaneFrame)
        let pip = try XCTUnwrap(layer.pipHostForTesting(floatID))
        XCTAssertTrue(pip.layer?.animation(forKey: FloatLayerView.settleAnimationKey) is CASpringAnimation)
        XCTAssertNil(layer.floatHostForTesting(floatID))
    }

    func test_throw_carries_its_velocity_into_the_corner_spring() throws {
        let layer = makeLayer(inWindow: false)
        layer.render(content(mode: .floating))
        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))
        let released = host.paneFrame.offsetBy(dx: 120, dy: -60)
        var motions: [CGRect] = []
        layer.onPipMotionForTesting = { motions.append($1) }

        host.onGestureBegan?(.move)
        host.onGestureChanged?(released)
        host.onGestureEnded?(.throwToPip(corner: .bottomRight), CGVector(dx: 1800, dy: -1400))
        layer.render(content(mode: .pip(corner: .bottomRight, order: 0)))

        XCTAssertEqual(motions, [released], "flies in from where it was let go")
        let pip = try XCTUnwrap(layer.pipHostForTesting(floatID))
        let spring = try XCTUnwrap(pip.layer?.animation(forKey: FloatLayerView.settleAnimationKey) as? CASpringAnimation)
        XCTAssertNotEqual(spring.initialVelocity, 0, "seeded with the throw")
    }

    func test_reduce_motion_crossfades_into_the_corner() throws {
        FloatMotion.reduceMotionOverride = true
        let layer = makeLayer(inWindow: false)
        layer.render(content(mode: .floating))

        layer.render(content(mode: .pip(corner: .bottomRight, order: 0)))

        let pip = try XCTUnwrap(layer.pipHostForTesting(floatID))
        let animation = try XCTUnwrap(
            pip.layer?.animation(forKey: FloatLayerView.settleAnimationKey) as? CABasicAnimation
        )
        XCTAssertFalse(animation is CASpringAnimation)
        XCTAssertEqual(animation.keyPath, "opacity", "no fly across the canvas, only a fade")
        XCTAssertEqual(animation.duration, FloatMotion.reducedDuration, accuracy: 0.0001)
    }

    func test_reduce_motion_restore_crossfades_in_place() throws {
        FloatMotion.reduceMotionOverride = true
        let layer = makeLayer(inWindow: false)
        layer.render(content(mode: .pip(corner: .bottomRight, order: 0)))

        layer.render(content(mode: .floating))

        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))
        let animation = try XCTUnwrap(
            host.layer?.animation(forKey: FloatLayerView.settleAnimationKey) as? CABasicAnimation
        )
        XCTAssertFalse(animation is CASpringAnimation)
        XCTAssertEqual(animation.keyPath, "opacity")
        XCTAssertEqual(animation.duration, FloatMotion.reducedDuration, accuracy: 0.0001)
    }

    func test_reduce_motion_restack_eases_without_overshoot() throws {
        FloatMotion.reduceMotionOverride = true
        let layer = makeLayer(inWindow: false)
        layer.render(content(mode: .pip(corner: .bottomRight, order: 0)))
        let pip = try XCTUnwrap(layer.pipHostForTesting(floatID))
        pip.layer?.removeAllAnimations()

        layer.pipWidth = FloatLayout.pipMediumWidth

        let animation = try XCTUnwrap(
            pip.layer?.animation(forKey: FloatLayerView.settleAnimationKey) as? CABasicAnimation
        )
        XCTAssertFalse(animation is CASpringAnimation)
        XCTAssertEqual(animation.keyPath, "transform", "a slot change is a short ease, not a fade")
        XCTAssertEqual(animation.duration, FloatMotion.reducedDuration, accuracy: 0.0001)
    }

    func test_restore_springs_from_the_pip_back_to_the_last_float_frame() throws {
        let layer = makeLayer(inWindow: false)
        layer.render(content(mode: .pip(corner: .bottomRight, order: 0)))
        let pipFrame = try XCTUnwrap(layer.pipHostForTesting(floatID)?.frame)
        var motions: [CGRect] = []
        layer.onPipMotionForTesting = { motions.append($1) }

        layer.render(content(mode: .floating))

        let host = try XCTUnwrap(layer.floatHostForTesting(floatID))
        XCTAssertEqual(host.paneFrame, CGRect(x: 100, y: 140, width: 600, height: 350), "lands at its last float frame")
        let visible = try XCTUnwrap(motions.first)
        XCTAssertEqual(visible.midX, pipFrame.midX, accuracy: 0.001, "starts on the PiP")
        XCTAssertEqual(visible.midY, pipFrame.midY, accuracy: 0.001)
        XCTAssertTrue(host.layer?.animation(forKey: FloatLayerView.settleAnimationKey) is CASpringAnimation)
        XCTAssertNil(layer.pipHostForTesting(floatID))
    }

    func test_fresh_pip_without_a_source_appears_in_place() throws {
        let layer = makeLayer(inWindow: false)
        var motions = 0
        layer.onPipMotionForTesting = { _, _ in motions += 1 }

        layer.render(content(mode: .pip(corner: .bottomRight, order: 0)))

        XCTAssertEqual(motions, 0, "a recipe or worklane switch shows the PiP where it is")
    }

    // MARK: - Layout, status

    func test_pip_width_follows_the_layer_setting_and_keeps_the_float_aspect() throws {
        let layer = makeLayer(inWindow: false)
        layer.pipWidth = FloatLayout.pipMediumWidth
        layer.bottomInset = PillBarLayout.barHeight

        layer.render(content(mode: .pip(corner: .bottomRight, order: 0)))

        let pip = try XCTUnwrap(layer.pipHostForTesting(floatID))
        XCTAssertEqual(pip.frame.width, 300)
        XCTAssertEqual(pip.frame.height, 300 * 350 / 600, accuracy: 0.001)
        XCTAssertEqual(pip.frame.maxX, canvas.maxX - FloatLayout.pipMargin)
        XCTAssertEqual(pip.frame.minY, FloatLayout.pipMargin + PillBarLayout.barHeight, "above the pill bar")
    }

    func test_pip_width_change_resizes_a_mounted_pip_live() throws {
        let layer = makeLayer(inWindow: false)
        layer.render(content(mode: .pip(corner: .bottomRight, order: 0)))
        let pip = try XCTUnwrap(layer.pipHostForTesting(floatID))
        XCTAssertEqual(pip.frame.width, FloatLayout.pipSmallWidth)
        pip.layer?.removeAllAnimations()

        layer.pipWidth = FloatLayout.pipMediumWidth

        XCTAssertTrue(layer.pipHostForTesting(floatID) === pip, "same PiP, no remount")
        XCTAssertEqual(pip.frame.width, FloatLayout.pipMediumWidth)
        XCTAssertEqual(pip.frame.maxX, canvas.maxX - FloatLayout.pipMargin, "still in its corner")
        XCTAssertEqual(pip.scaleViewForTesting.bounds.size, CGSize(width: 600, height: 350), "grid size untouched")
        XCTAssertTrue(
            pip.layer?.animation(forKey: FloatLayerView.settleAnimationKey) is CASpringAnimation,
            "springs to the new size like a restack"
        )
    }

    func test_status_strip_follows_content_and_live_updates() throws {
        let layer = makeLayer(inWindow: false)
        var pipContent = content(mode: .pip(corner: .bottomRight, order: 0))
        pipContent.pipStatusByPaneID = [floatID: item(.running)]
        layer.render(pipContent)
        let pip = try XCTUnwrap(layer.pipHostForTesting(floatID))
        XCTAssertEqual(pip.statusStripForTesting.statusWordForTesting, "Working")

        layer.updatePipStatuses([floatID: item(.needsInput)])

        XCTAssertEqual(pip.statusStripForTesting.statusWordForTesting, "Needs input")
        XCTAssertFalse(pip.glowLayerForTesting.isHidden)
    }

    func test_pip_legend_actions_reach_the_layer_callback() throws {
        let layer = makeLayer(inWindow: false)
        layer.render(content(mode: .pip(corner: .bottomRight, order: 0)))
        var received: [(PaneID, PaneBorderAction)] = []
        layer.onFloatActionRequested = { received.append(($0, $1)) }
        let pip = try XCTUnwrap(layer.pipHostForTesting(floatID))
        pip.setHovered(true)

        try XCTUnwrap(pip.actionsViewForTesting.buttonForTesting(.restore)).performClick(nil)

        XCTAssertEqual(received.map(\.0), [floatID])
        XCTAssertEqual(received.map(\.1), [.restore])
    }

    func test_content_builds_pip_statuses_for_pips_only() {
        let pip = FloatingPaneState(
            pane: PaneState(id: PaneID("p"), title: "watch"),
            mode: .pip(corner: .topLeft, order: 0),
            floatFrame: floatFrame,
            stackOrder: 0,
            origin: nil
        )
        let floating = FloatingPaneState(
            pane: PaneState(id: PaneID("f"), title: "edit"),
            mode: .floating,
            floatFrame: floatFrame,
            stackOrder: 1,
            origin: nil
        )
        var worklane = WorklaneState(
            id: WorklaneID("wl"),
            title: nil,
            paneStripState: PaneStripState(panes: [PaneState(id: PaneID("t"), title: "t")], focusedPaneID: PaneID("t")),
            auxiliaryStateByPaneID: [:]
        )
        worklane.floatingPanes = [pip, floating]

        let statuses = FloatLayerContent(worklane: worklane).pipStatusByPaneID

        XCTAssertEqual(Array(statuses.keys), [PaneID("p")])
        XCTAssertEqual(statuses[PaneID("p")]?.name, "watch")
    }

    // MARK: - Fixtures

    private func makeLayer(inWindow: Bool) -> FloatLayerView {
        let registry = PaneRuntimeRegistry(adapterFactory: { [unowned self] paneID in
            let adapter = PipViewportSpyAdapter()
            self.adapters[paneID] = adapter
            return adapter
        })
        let layer = FloatLayerView(runtimeRegistry: registry)
        layer.frame = canvas
        if inWindow {
            let window = NSWindow(
                contentRect: canvas,
                styleMask: [.borderless],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            let root = NSView(frame: canvas)
            window.contentView = root
            root.addSubview(layer)
            self.window = window
        }
        return layer
    }

    private func content(mode: FloatingPaneMode) -> FloatLayerContent {
        FloatLayerContent(
            floats: [
                FloatingPaneState(
                    pane: PaneState(id: floatID, title: "float"),
                    mode: mode,
                    floatFrame: floatFrame,
                    stackOrder: 0,
                    origin: nil
                ),
            ],
            floatsHidden: false,
            focusedFloatID: nil
        )
    }

    private func item(_ attention: WorklaneAttentionState?) -> PillBarItem {
        PillBarItem(paneID: floatID, name: "float", subtitle: nil, attention: attention)
    }
}

private extension FloatLayerView {
    func render(_ content: FloatLayerContent) {
        render(content, theme: ZenttyTheme.fallback(for: nil), showPaneBorders: true, smoothScrollingEnabled: false)
    }
}

@MainActor
private final class PipViewportSpyAdapter: TerminalAdapter {
    let view = PipViewportSpyView()
    var hasScrollback = false
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var metadataDidChange: ((TerminalMetadata) -> Void)?
    var eventDidOccur: ((TerminalEvent) -> Void)?

    func makeTerminalView() -> NSView { view }
    func startSession(using request: TerminalSessionRequest) throws {}
    func close() {}
    func sendText(_ text: String) {}
    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {}
}

private final class PipViewportSpyView: NSView, TerminalViewportSyncControlling {
    struct Entry {
        let suspended: Bool
        let wasInPip: Bool
        let containerSize: CGSize?
    }

    private(set) var isSuspended: Bool?
    var log: [Entry] = []
    private(set) var forcedSyncs: [Entry] = []

    func setViewportSyncSuspended(_ suspended: Bool) {
        isSuspended = suspended
        log.append(entry(suspended: suspended))
    }

    func forceViewportSync() {
        forcedSyncs.append(entry(suspended: isSuspended ?? false))
    }

    private func entry(suspended: Bool) -> Entry {
        var container: PaneContainerView?
        var inPip = false
        var view = superview
        while let current = view {
            if container == nil, let match = current as? PaneContainerView { container = match }
            if current is PipContainerView { inPip = true }
            view = current.superview
        }
        return Entry(suspended: suspended, wasInPip: inPip, containerSize: container?.frame.size)
    }
}
