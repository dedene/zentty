import XCTest
@testable import Zentty

@MainActor
final class PaneCommandExecutorTests: XCTestCase {
    private let worklaneID = WorklaneID("worklane-main")
    private let paneA = PaneID("pane-a")
    private let paneB = PaneID("pane-b")

    // MARK: - split / grid / resize

    func test_split_settles_canvas_and_creates_pane() {
        let store = makeStore()
        let canvas = StubCanvas()
        let executor = makeExecutor(store: store, canvas: canvas)

        let newPaneID = executor.splitWithLayout(
            placement: .afterFocused,
            isHorizontal: true,
            layout: .none
        )

        XCTAssertNotNil(newPaneID)
        XCTAssertEqual(canvas.settleCount, 1)
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.count, 2)
    }

    func test_apply_grid_creates_grid_panes() throws {
        let store = makeStore()
        let canvas = StubCanvas()
        let executor = makeExecutor(store: store, canvas: canvas)

        _ = try executor.applyGrid(
            sourcePaneID: paneA,
            rows: 1,
            columns: 2,
            command: nil,
            includeSource: true,
            focus: .source
        )

        XCTAssertEqual(canvas.settleCount, 1)
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.count, 2)
    }

    func test_resize_right_settles_pane_strip_presentation() {
        let store = makeStore()
        let canvas = StubCanvas()
        let executor = makeExecutor(store: store, canvas: canvas)

        executor.handlePaneCommand(.resizeRight)

        XCTAssertEqual(canvas.settleCount, 1)
    }

    // MARK: - close-confirmation gating

    func test_close_focused_pane_without_confirmation_closes_directly() throws {
        let store = makeStore(paneCount: 2)
        let configStore = makeConfigStore()
        try configStore.update { $0.confirmations.confirmBeforeClosingPane = false }
        let spy = HooksSpy()
        let executor = makeExecutor(store: store, configStore: configStore, hooks: spy.makeHooks())

        executor.handlePaneCommand(.closeFocusedPane)

        XCTAssertNil(spy.presentedReason)
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.count, 1)
    }

    func test_close_focused_pane_with_confirmation_and_reason_presents_then_closes_on_confirm() throws {
        let store = makeStore(paneCount: 2, focusedHasHistory: true)
        let configStore = makeConfigStore()
        try configStore.update { $0.confirmations.confirmBeforeClosingPane = true }
        let spy = HooksSpy()
        let executor = makeExecutor(store: store, configStore: configStore, hooks: spy.makeHooks())

        executor.handlePaneCommand(.closeFocusedPane)

        // Gated: the confirmation is presented and the pane is NOT yet closed.
        guard case .sessionHistory = spy.presentedReason else {
            return XCTFail("expected sessionHistory reason, got \(String(describing: spy.presentedReason))")
        }
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.count, 2)

        // Confirming actually closes the pane.
        try XCTUnwrap(spy.capturedOnConfirm)()
        XCTAssertEqual(store.activeWorklane?.paneStripState.panes.count, 1)
    }

    // MARK: - Helpers

    private func makeExecutor(
        store: WorklaneStore,
        configStore: AppConfigStore? = nil,
        canvas: StubCanvas = StubCanvas(),
        hooks: PaneCommandExecutor.UIHooks? = nil
    ) -> PaneCommandExecutor {
        PaneCommandExecutor(
            worklaneStore: store,
            configStore: configStore ?? makeConfigStore(),
            runtimeRegistry: PaneRuntimeRegistry(),
            canvas: canvas,
            hooks: hooks ?? HooksSpy().makeHooks()
        )
    }

    private func makeConfigStore() -> AppConfigStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaneCommandExecutorTests-\(UUID().uuidString).toml")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return AppConfigStore(fileURL: url)
    }

    private func makeStore(paneCount: Int = 1, focusedHasHistory: Bool = false) -> WorklaneStore {
        let store = WorklaneStore()
        var panes = [PaneState(id: paneA, title: "server")]
        if paneCount >= 2 {
            panes.append(PaneState(id: paneB, title: "frontend"))
        }
        var auxiliary: [PaneID: PaneAuxiliaryState] = [:]
        if focusedHasHistory {
            var aux = PaneAuxiliaryState()
            aux.hasCommandHistory = true
            auxiliary[paneA] = aux
        }
        store.replaceWorklanes([
            WorklaneState(
                id: worklaneID,
                title: nil,
                paneStripState: PaneStripState(panes: panes, focusedPaneID: paneA),
                auxiliaryStateByPaneID: auxiliary
            )
        ], activeWorklaneID: worklaneID)
        return store
    }
}

@MainActor
private final class StubCanvas: PaneCanvasGeometry {
    var boundsSize: CGSize = CGSize(width: 1200, height: 800)
    var leadingVisibleInset: CGFloat = 0
    private(set) var settleCount = 0

    func settlePaneStripPresentationNow() { settleCount += 1 }
    func centerFocusedInteriorPaneOnNextRender() {}
    func clearPendingPaneStripTargetOffsetOverride() {}
    func shiftPaneStripTargetOffsetOnNextRender(by: CGFloat) {}
}

@MainActor
private final class HooksSpy {
    var presentedReason: WorklaneStore.PaneCloseReason?
    var capturedOnConfirm: (() -> Void)?
    var toastMessages: [String] = []
    var windowCloseCount = 0

    func makeHooks() -> PaneCommandExecutor.UIHooks {
        PaneCommandExecutor.UIHooks(
            presentClosePaneConfirmation: { [self] reason, onConfirm in
                presentedReason = reason
                capturedOnConfirm = onConfirm
            },
            showToast: { [self] message in toastMessages.append(message) },
            requestWindowClose: { [self] in windowCloseCount += 1 }
        )
    }
}
