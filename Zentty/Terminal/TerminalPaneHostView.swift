import AppKit
import Foundation

@MainActor
final class TerminalPaneHostView: NSView {
    private let adapter: any TerminalAdapter
    private let terminalView: NSView
    private var hasStartedSession = false

    var onMetadataDidChange: ((TerminalMetadata) -> Void)? {
        didSet {
            adapter.metadataDidChange = onMetadataDidChange
        }
    }
    var onFocusDidChange: ((Bool) -> Void)? {
        didSet {
            (terminalView as? any TerminalFocusReporting)?.onFocusDidChange = onFocusDidChange
        }
    }

    init(adapter: any TerminalAdapter) {
        self.adapter = adapter
        self.terminalView = adapter.makeTerminalView()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        (terminalView as? any TerminalFocusReporting)?.onFocusDidChange = onFocusDidChange
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startSessionIfNeeded(using request: TerminalSessionRequest) throws {
        guard !hasStartedSession else {
            return
        }

        try adapter.startSession(using: request)
        hasStartedSession = true
    }

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        adapter.setSurfaceActivity(activity)
    }

    func prepareSessionStart(from sourceAdapter: (any TerminalAdapter)?) {
        (adapter as? any TerminalSessionInheritanceConfiguring)?
            .prepareSessionStart(from: sourceAdapter)
    }

    func focusTerminal() {
        guard window?.firstResponder !== terminalView else {
            return
        }

        window?.makeFirstResponder(terminalView)
    }

    private func setup() {
        addSubview(terminalView)
        terminalView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    var terminalViewForTesting: NSView {
        terminalView
    }
}

struct PaneRuntimeSnapshot: Equatable {
    var metadata: TerminalMetadata
    var startupFailureMessage: String?
    var hasReceivedMetadata: Bool
}

@MainActor
final class PaneRuntime {
    static let startupFailureMessage = "GhosttyKit could not start this pane. Check your shell environment and retry."

    private let paneIDValue: PaneID
    private let adapterValue: any TerminalAdapter
    private let hostViewValue: TerminalPaneHostView
    private let metadataSink: (PaneID, TerminalMetadata) -> Void
    private var sessionRequest: TerminalSessionRequest
    private var hasAttemptedStart = false
    private var hasReceivedMetadata = false
    private var observers: [UUID: (PaneRuntimeSnapshot) -> Void] = [:]

    private(set) var metadata = TerminalMetadata() {
        didSet {
            notifyObservers()
        }
    }

    private(set) var startupFailureMessageValue: String? {
        didSet {
            guard startupFailureMessageValue != oldValue else {
                return
            }

            notifyObservers()
        }
    }

    init(
        pane: PaneState,
        adapter: any TerminalAdapter,
        metadataSink: @escaping (PaneID, TerminalMetadata) -> Void
    ) {
        paneIDValue = pane.id
        sessionRequest = pane.sessionRequest
        adapterValue = adapter
        hostViewValue = TerminalPaneHostView(adapter: adapter)
        self.metadataSink = metadataSink
        hostViewValue.onMetadataDidChange = { [weak self] metadata in
            self?.handleMetadataDidChange(metadata)
        }
    }

    var paneID: PaneID {
        paneIDValue
    }

    var hostView: TerminalPaneHostView {
        hostViewValue
    }

    var adapter: any TerminalAdapter {
        adapterValue
    }

    var snapshot: PaneRuntimeSnapshot {
        PaneRuntimeSnapshot(
            metadata: metadata,
            startupFailureMessage: startupFailureMessageValue,
            hasReceivedMetadata: hasReceivedMetadata
        )
    }

    func update(pane: PaneState) {
        sessionRequest = pane.sessionRequest
    }

    func ensureStarted() {
        guard !hasAttemptedStart else {
            return
        }

        hasAttemptedStart = true
        attemptStart()
    }

    func retryStartSession() {
        hasAttemptedStart = true
        attemptStart()
    }

    func setSurfaceActivity(_ activity: TerminalSurfaceActivity) {
        hostViewValue.setSurfaceActivity(activity)
    }

    func prepareSessionStart(from sourceRuntime: PaneRuntime?) {
        hostViewValue.prepareSessionStart(from: sourceRuntime?.adapter)
    }

    func addObserver(_ observer: @escaping (PaneRuntimeSnapshot) -> Void) -> UUID {
        let observerID = UUID()
        observers[observerID] = observer
        observer(snapshot)
        return observerID
    }

    func removeObserver(_ observerID: UUID) {
        observers.removeValue(forKey: observerID)
    }

    private func attemptStart() {
        do {
            try hostViewValue.startSessionIfNeeded(using: sessionRequest)
            startupFailureMessageValue = nil
        } catch {
            startupFailureMessageValue = Self.startupFailureMessage
        }
    }

    private func handleMetadataDidChange(_ metadata: TerminalMetadata) {
        hasReceivedMetadata = true
        self.metadata = metadata
        metadataSink(paneIDValue, metadata)
    }

    private func notifyObservers() {
        let snapshot = snapshot
        observers.values.forEach { observer in
            observer(snapshot)
        }
    }
}

@MainActor
final class PaneRuntimeRegistry {
    typealias AdapterFactory = @MainActor (PaneID) -> any TerminalAdapter

    private let adapterFactory: AdapterFactory
    private var runtimes: [PaneID: PaneRuntime] = [:]

    var onMetadataDidChange: ((PaneID, TerminalMetadata) -> Void)?

    init(adapterFactory: @escaping AdapterFactory = { _ in TerminalAdapterRegistry.makeAdapter() }) {
        self.adapterFactory = adapterFactory
    }

    func runtime(for pane: PaneState) -> PaneRuntime {
        if let runtime = runtimes[pane.id] {
            runtime.update(pane: pane)
            return runtime
        }

        let runtime = PaneRuntime(
            pane: pane,
            adapter: adapterFactory(pane.id),
            metadataSink: { [weak self] paneID, metadata in
                self?.onMetadataDidChange?(paneID, metadata)
            }
        )
        runtimes[pane.id] = runtime
        return runtime
    }

    func runtime(for paneID: PaneID) -> PaneRuntime? {
        runtimes[paneID]
    }

    func synchronize(with workspaces: [WorkspaceState]) {
        var nextPaneIDs = Set<PaneID>()

        for workspace in workspaces {
            for pane in workspace.paneStripState.panes {
                nextPaneIDs.insert(pane.id)
                let runtime = runtime(for: pane)
                let sourceRuntime = pane.sessionRequest.inheritFromPaneID.flatMap { runtimes[$0] }
                runtime.prepareSessionStart(from: sourceRuntime)
                runtime.ensureStarted()
            }
        }

        let obsoletePaneIDs = Set(runtimes.keys).subtracting(nextPaneIDs)
        obsoletePaneIDs.forEach { paneID in
            runtimes.removeValue(forKey: paneID)
        }
    }

    func updateSurfaceActivities(
        workspaces: [WorkspaceState],
        activeWorkspaceID: WorkspaceID,
        windowIsVisible: Bool,
        windowIsKey: Bool
    ) {
        for workspace in workspaces {
            let isActiveWorkspace = workspace.id == activeWorkspaceID
            for pane in workspace.paneStripState.panes {
                let isVisible = windowIsVisible && isActiveWorkspace
                let isFocused = isVisible && windowIsKey && pane.id == workspace.paneStripState.focusedPaneID
                let runtime = runtime(for: pane)
                runtime.setSurfaceActivity(
                    TerminalSurfaceActivity(isVisible: isVisible, isFocused: isFocused)
                )
            }
        }
    }
}
