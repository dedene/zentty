import XCTest
@testable import Zentty

@MainActor
final class WorklaneStoreCrossWindowTransferTests: XCTestCase {

    private let columnWidth: CGFloat = 100

    func test_extract_removesPaneFromSourceWorklane() throws {
        let store = makeMultiPaneStore()
        let movedID = PaneID("p1")

        let payload = try XCTUnwrap(store.extractPaneForCrossWindowTransfer(
            paneID: movedID,
            singleColumnWidth: columnWidth
        ))

        XCTAssertEqual(payload.pane.id, movedID)
        XCTAssertFalse(payload.sourceWorklaneRemoved)
        XCTAssertFalse(payload.sourceWindowShouldClose)

        let sourceWorklane = try XCTUnwrap(store.worklanes.first(where: { $0.id == WorklaneID("source") }))
        XCTAssertFalse(sourceWorklane.paneStripState.panes.contains(where: { $0.id == movedID }))
        XCTAssertEqual(sourceWorklane.paneStripState.panes.count, 1)
    }

    func test_extract_emptySourceWithOtherWorklanes_removesSourceWorklane() throws {
        let store = makeStoreWithSingleSourcePaneAndAdditionalWorklane()
        let movedID = PaneID("solo")

        let payload = try XCTUnwrap(store.extractPaneForCrossWindowTransfer(
            paneID: movedID,
            singleColumnWidth: columnWidth
        ))

        XCTAssertTrue(payload.sourceWorklaneRemoved)
        XCTAssertFalse(payload.sourceWindowShouldClose)
        XCTAssertEqual(store.worklanes.map(\.id), [WorklaneID("other")])
        XCTAssertEqual(store.activeWorklaneID, WorklaneID("other"))
    }

    func test_extract_lastPaneInOnlyWorklane_flagsWindowShouldClose() throws {
        let store = makeStoreWithSingleSoloWorklane()
        let movedID = PaneID("only")

        let payload = try XCTUnwrap(store.extractPaneForCrossWindowTransfer(
            paneID: movedID,
            singleColumnWidth: columnWidth
        ))

        XCTAssertFalse(payload.sourceWorklaneRemoved)
        XCTAssertTrue(payload.sourceWindowShouldClose)
        XCTAssertEqual(store.worklanes.count, 1)
        XCTAssertTrue(store.worklanes[0].paneStripState.panes.isEmpty)
    }

    func test_extract_emitsPaneStructureNotification_whenSourceRetained() throws {
        let store = makeMultiPaneStore()
        var changes: [WorklaneChange] = []
        store.subscribe { changes.append($0) }

        _ = try XCTUnwrap(store.extractPaneForCrossWindowTransfer(
            paneID: PaneID("p1"),
            singleColumnWidth: columnWidth
        ))

        XCTAssertTrue(changes.contains(.paneStructure(WorklaneID("source"))))
        XCTAssertFalse(changes.contains(.worklaneListChanged))
    }

    func test_extract_emitsWorklaneListChangedNotification_whenSourceRemoved() throws {
        let store = makeStoreWithSingleSourcePaneAndAdditionalWorklane()
        var changes: [WorklaneChange] = []
        store.subscribe { changes.append($0) }

        _ = try XCTUnwrap(store.extractPaneForCrossWindowTransfer(
            paneID: PaneID("solo"),
            singleColumnWidth: columnWidth
        ))

        XCTAssertTrue(changes.contains(.worklaneListChanged))
    }

    func test_insert_appendsPaneAsNewColumnInTarget() throws {
        let sourceStore = makeMultiPaneStore()
        let destinationStore = makeDestinationStore()

        let payload = try XCTUnwrap(sourceStore.extractPaneForCrossWindowTransfer(
            paneID: PaneID("p1"),
            singleColumnWidth: columnWidth
        ))

        destinationStore.insertExtractedPane(
            payload,
            intoWorklane: WorklaneID("dest"),
            singleColumnWidth: columnWidth
        )

        let target = try XCTUnwrap(destinationStore.worklanes.first(where: { $0.id == WorklaneID("dest") }))
        XCTAssertEqual(target.paneStripState.panes.map(\.id), [PaneID("dest-pane"), PaneID("p1")])
    }

    func test_insert_switchesActiveWorklaneToTarget() throws {
        let sourceStore = makeMultiPaneStore()
        let destinationStore = makeDestinationStoreWithTwoWorklanes()
        XCTAssertEqual(destinationStore.activeWorklaneID, WorklaneID("other"))

        let payload = try XCTUnwrap(sourceStore.extractPaneForCrossWindowTransfer(
            paneID: PaneID("p1"),
            singleColumnWidth: columnWidth
        ))

        destinationStore.insertExtractedPane(
            payload,
            intoWorklane: WorklaneID("dest"),
            singleColumnWidth: columnWidth
        )

        XCTAssertEqual(destinationStore.activeWorklaneID, WorklaneID("dest"))
    }

    func test_insert_restoresAuxiliaryState() throws {
        let auxPaneID = PaneID("p1")
        let aux = PaneAuxiliaryState()
        let sourceStore = makeMultiPaneStore(auxiliaryFor: auxPaneID, value: aux)
        let destinationStore = makeDestinationStore()

        let payload = try XCTUnwrap(sourceStore.extractPaneForCrossWindowTransfer(
            paneID: auxPaneID,
            singleColumnWidth: columnWidth
        ))
        XCTAssertNotNil(payload.auxiliary)

        destinationStore.insertExtractedPane(
            payload,
            intoWorklane: WorklaneID("dest"),
            singleColumnWidth: columnWidth
        )

        let target = try XCTUnwrap(destinationStore.worklanes.first(where: { $0.id == WorklaneID("dest") }))
        XCTAssertNotNil(target.auxiliaryStateByPaneID[auxPaneID])
    }

    func test_insert_emitsPaneStructureAndActiveWorklaneNotifications() throws {
        let sourceStore = makeMultiPaneStore()
        let destinationStore = makeDestinationStore()
        var destinationChanges: [WorklaneChange] = []
        destinationStore.subscribe { destinationChanges.append($0) }

        let payload = try XCTUnwrap(sourceStore.extractPaneForCrossWindowTransfer(
            paneID: PaneID("p1"),
            singleColumnWidth: columnWidth
        ))

        destinationStore.insertExtractedPane(
            payload,
            intoWorklane: WorklaneID("dest"),
            singleColumnWidth: columnWidth
        )

        XCTAssertTrue(destinationChanges.contains(.paneStructure(WorklaneID("dest"))))
        XCTAssertTrue(destinationChanges.contains(.activeWorklaneChanged))
    }

    func test_insert_unknownTargetWorklane_returnsFalseAndIsNoOp() throws {
        let sourceStore = makeMultiPaneStore()
        let destinationStore = makeDestinationStore()
        let originalDestPanes = destinationStore.worklanes
            .first(where: { $0.id == WorklaneID("dest") })?
            .paneStripState.panes.count ?? 0

        let payload = try XCTUnwrap(sourceStore.extractPaneForCrossWindowTransfer(
            paneID: PaneID("p1"),
            singleColumnWidth: columnWidth
        ))

        let inserted = destinationStore.insertExtractedPane(
            payload,
            intoWorklane: WorklaneID("missing"),
            singleColumnWidth: columnWidth
        )

        XCTAssertFalse(inserted)
        let target = try XCTUnwrap(destinationStore.worklanes.first(where: { $0.id == WorklaneID("dest") }))
        XCTAssertEqual(target.paneStripState.panes.count, originalDestPanes)
    }

    func test_insert_returnsTrueOnSuccess() throws {
        let sourceStore = makeMultiPaneStore()
        let destinationStore = makeDestinationStore()

        let payload = try XCTUnwrap(sourceStore.extractPaneForCrossWindowTransfer(
            paneID: PaneID("p1"),
            singleColumnWidth: columnWidth
        ))

        let inserted = destinationStore.insertExtractedPane(
            payload,
            intoWorklane: WorklaneID("dest"),
            singleColumnWidth: columnWidth
        )

        XCTAssertTrue(inserted)
    }

    func test_insert_usesDestinationSingleColumnWidthForNewColumn() throws {
        let sourceStore = makeMultiPaneStore()
        let destinationStore = makeDestinationStore()
        let destSingleColumnWidth: CGFloat = 250

        let payload = try XCTUnwrap(sourceStore.extractPaneForCrossWindowTransfer(
            paneID: PaneID("p1"),
            singleColumnWidth: columnWidth
        ))

        destinationStore.insertExtractedPane(
            payload,
            intoWorklane: WorklaneID("dest"),
            singleColumnWidth: destSingleColumnWidth
        )

        let target = try XCTUnwrap(destinationStore.worklanes.first(where: { $0.id == WorklaneID("dest") }))
        let newColumn = try XCTUnwrap(target.paneStripState.columns.last)
        XCTAssertEqual(newColumn.width, destSingleColumnWidth, accuracy: 0.5)
    }

    // MARK: - Fixtures

    private func makeMultiPaneStore(
        auxiliaryFor auxPaneID: PaneID? = nil,
        value: PaneAuxiliaryState? = nil
    ) -> WorklaneStore {
        var aux: [PaneID: PaneAuxiliaryState] = [:]
        if let auxPaneID, let value {
            aux[auxPaneID] = value
        }
        return WorklaneStore(
            windowID: WindowID("wd_source"),
            worklanes: [
                WorklaneState(
                    id: WorklaneID("source"),
                    title: "SRC",
                    paneStripState: PaneStripState(
                        panes: [
                            PaneState(id: PaneID("p1"), title: "vim"),
                            PaneState(id: PaneID("p2"), title: "shell"),
                        ],
                        focusedPaneID: PaneID("p1")
                    ),
                    auxiliaryStateByPaneID: aux
                )
            ],
            activeWorklaneID: WorklaneID("source")
        )
    }

    private func makeStoreWithSingleSourcePaneAndAdditionalWorklane() -> WorklaneStore {
        WorklaneStore(
            windowID: WindowID("wd_source"),
            worklanes: [
                WorklaneState(
                    id: WorklaneID("source"),
                    title: "SRC",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: PaneID("solo"), title: "vim")],
                        focusedPaneID: PaneID("solo")
                    )
                ),
                WorklaneState(
                    id: WorklaneID("other"),
                    title: "OTHER",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: PaneID("other-pane"), title: "shell")],
                        focusedPaneID: PaneID("other-pane")
                    )
                ),
            ],
            activeWorklaneID: WorklaneID("source")
        )
    }

    private func makeStoreWithSingleSoloWorklane() -> WorklaneStore {
        WorklaneStore(
            windowID: WindowID("wd_source"),
            worklanes: [
                WorklaneState(
                    id: WorklaneID("source"),
                    title: "SRC",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: PaneID("only"), title: "vim")],
                        focusedPaneID: PaneID("only")
                    )
                )
            ],
            activeWorklaneID: WorklaneID("source")
        )
    }

    private func makeDestinationStore() -> WorklaneStore {
        WorklaneStore(
            windowID: WindowID("wd_dest"),
            worklanes: [
                WorklaneState(
                    id: WorklaneID("dest"),
                    title: "DEST",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: PaneID("dest-pane"), title: "ssh")],
                        focusedPaneID: PaneID("dest-pane")
                    )
                )
            ],
            activeWorklaneID: WorklaneID("dest")
        )
    }

    private func makeDestinationStoreWithTwoWorklanes() -> WorklaneStore {
        WorklaneStore(
            windowID: WindowID("wd_dest"),
            worklanes: [
                WorklaneState(
                    id: WorklaneID("dest"),
                    title: "DEST",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: PaneID("dest-pane"), title: "ssh")],
                        focusedPaneID: PaneID("dest-pane")
                    )
                ),
                WorklaneState(
                    id: WorklaneID("other"),
                    title: "OTHER",
                    paneStripState: PaneStripState(
                        panes: [PaneState(id: PaneID("other-pane"), title: "shell")],
                        focusedPaneID: PaneID("other-pane")
                    )
                ),
            ],
            activeWorklaneID: WorklaneID("other")
        )
    }
}
