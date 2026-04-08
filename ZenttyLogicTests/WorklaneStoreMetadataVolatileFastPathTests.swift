import XCTest
@testable import Zentty

@MainActor
final class WorklaneStoreMetadataVolatileFastPathTests: XCTestCase {
    func test_volatileTitleTick_fires_volatileAgentTitleUpdated_not_auxiliaryStateUpdated() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        // Seed a running codex volatile title via the normal slow path.
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        var received: [WorklaneChange] = []
        let subscription = store.subscribe { change in
            received.append(change)
        }
        defer { store.unsubscribe(subscription) }

        // Pure volatile tick — only the elapsed counter moves, phase+subject signature unchanged.
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠙ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        let volatileUpdates = received.filter { change in
            if case .volatileAgentTitleUpdated = change { return true }
            return false
        }
        let auxiliaryUpdates = received.filter { change in
            if case .auxiliaryStateUpdated = change { return true }
            return false
        }
        XCTAssertEqual(volatileUpdates.count, 1, "expected one volatileAgentTitleUpdated")
        XCTAssertEqual(auxiliaryUpdates.count, 0, "slow path should not fire for volatile-only tick")
    }

    func test_volatileTitleTick_updates_stored_metadata() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠙ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        XCTAssertEqual(
            store.activeWorklane?.auxiliaryStateByPaneID[paneID]?.metadata?.title,
            "Working ⠙ zentty"
        )
    }

    func test_meaningfulTitleChange_takes_slowPath() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        var received: [WorklaneChange] = []
        let subscription = store.subscribe { change in
            received.append(change)
        }
        defer { store.unsubscribe(subscription) }

        // Phase transition running → idle — not volatileTitleOnly.
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Ready | zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        let volatileUpdates = received.filter { change in
            if case .volatileAgentTitleUpdated = change { return true }
            return false
        }
        XCTAssertEqual(volatileUpdates.count, 0, "meaningful transition must not take the fast path")
    }

    func test_interactionRequired_declinesFastPath() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        // Put the agent into an approval-required state via explicit payload.
        store.applyAgentStatusPayload(
            AgentStatusPayload(
                worklaneID: store.activeWorklaneID,
                paneID: paneID,
                signalKind: .lifecycle,
                state: .needsInput,
                origin: .explicitAPI,
                toolName: "Codex",
                text: "Approval requested",
                interactionKind: .approval,
                confidence: .explicit,
                sessionID: "session-1",
                artifactKind: nil,
                artifactLabel: nil,
                artifactURL: nil
            )
        )
        // Seed a metadata title that would otherwise be a volatile tick.
        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        var received: [WorklaneChange] = []
        let subscription = store.subscribe { change in
            received.append(change)
        }
        defer { store.unsubscribe(subscription) }

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠙ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        let volatileUpdates = received.filter { change in
            if case .volatileAgentTitleUpdated = change { return true }
            return false
        }
        XCTAssertEqual(
            volatileUpdates.count,
            0,
            "fast path must decline while the agent state requires human attention"
        )
    }

    func test_hiddenWorklane_coalescesVolatileNotifications() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let activeWorklaneID = try XCTUnwrap(store.activeWorklane?.id)

        // Open a second worklane and leave the first active.
        store.createWorklane()
        store.selectWorklane(id: activeWorklaneID)
        let hiddenWorklane = try XCTUnwrap(
            store.worklanes.first(where: { $0.id != activeWorklaneID })
        )
        let hiddenPaneID = try XCTUnwrap(hiddenWorklane.paneStripState.focusedPaneID)

        // Seed running codex state in the hidden worklane.
        store.updateMetadata(
            paneID: hiddenPaneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        var received: [WorklaneChange] = []
        let subscription = store.subscribe { change in
            received.append(change)
        }
        defer { store.unsubscribe(subscription) }

        // Fire three rapid volatile ticks on the hidden pane — different
        // spinner frames so each call is a non-noop volatile update.
        let frames = ["⠙", "⠹", "⠸"]
        for frame in frames {
            store.updateMetadata(
                paneID: hiddenPaneID,
                metadata: TerminalMetadata(
                    title: "Working \(frame) zentty",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "codex",
                    gitBranch: "main"
                )
            )
        }

        let volatileUpdates = received.filter { change in
            if case .volatileAgentTitleUpdated = change { return true }
            return false
        }
        XCTAssertEqual(
            volatileUpdates.count,
            1,
            "hidden-worklane volatile ticks within the throttle window must coalesce to a single notify"
        )

        // Each tick must still have updated the stored metadata — only the UI notify is throttled.
        XCTAssertEqual(
            store.worklanes.first(where: { $0.id == hiddenWorklane.id })?
                .auxiliaryStateByPaneID[hiddenPaneID]?.metadata?.title,
            "Working ⠸ zentty"
        )
    }

    func test_activeWorklane_doesNotCoalesceVolatileNotifications() throws {
        let store = WorklaneStore(readyStatusDebounceInterval: 0)
        store.knownNonRepositoryPaths.insert("/tmp/project")
        let paneID = try XCTUnwrap(store.activeWorklane?.paneStripState.focusedPaneID)

        store.updateMetadata(
            paneID: paneID,
            metadata: TerminalMetadata(
                title: "Working ⠋ zentty",
                currentWorkingDirectory: "/tmp/project",
                processName: "codex",
                gitBranch: "main"
            )
        )

        var received: [WorklaneChange] = []
        let subscription = store.subscribe { change in
            received.append(change)
        }
        defer { store.unsubscribe(subscription) }

        let frames = ["⠙", "⠹", "⠸"]
        for frame in frames {
            store.updateMetadata(
                paneID: paneID,
                metadata: TerminalMetadata(
                    title: "Working \(frame) zentty",
                    currentWorkingDirectory: "/tmp/project",
                    processName: "codex",
                    gitBranch: "main"
                )
            )
        }

        let volatileUpdates = received.filter { change in
            if case .volatileAgentTitleUpdated = change { return true }
            return false
        }
        XCTAssertEqual(
            volatileUpdates.count,
            3,
            "active-worklane volatile ticks must not be throttled — they drive the realtime spinner"
        )
    }
}
