import Foundation
import OSLog

private let sessionScrollbackLogger = Logger(subsystem: "be.zenjoy.zentty", category: "SessionScrollback")

/// Keeps each pane's output across an app relaunch.
///
/// Capture reuses the Undo Close Pane provider (`WorklaneStore.scrollbackProvider`)
/// on the main thread; sanitizing, capping and the disk writes run on a
/// private serial queue. On restore, the pane's environment names its file in
/// `environmentKey` and Zentty's shell integration prints it before the first
/// prompt, so the saved text is shown, never typed into the shell, and an agent
/// pane's resume command still runs exactly as before, after it.
///
/// Files are named per launch (`<pane>-<launchID>.txt`). The file a restored
/// pane was pointed at is never rewritten, and is purged once the pane saves
/// newer output, so a copy of the variable that leaked to a child process
/// (bash and nushell load the integration after the user's rc file) can only
/// ever print that old output, and only until the next save.
@MainActor
final class SessionScrollbackCoordinator {
    /// Read and unset by the shell integration (zsh, bash, fish, nushell).
    static let environmentKey = "ZENTTY_RESTORED_SCROLLBACK_FILE"
    static let defaultCheckpointInterval: Duration = .seconds(180)

    struct CaptureSource {
        var paneIDs: [PaneID]
        /// Panes running a command or an agent turn. Their output can grow
        /// without any metadata change, so every checkpoint reads them.
        var busyPaneIDs: Set<PaneID> = []
        var read: (PaneID) -> String?
    }

    let archive: SessionScrollbackArchive
    let launchID: String
    /// Fired when a pane gained or changed its file, so the recipe references it.
    var onReferencesChanged: (() -> Void)?
    var sourcesProvider: () -> [CaptureSource] = { [] }

    private let writer: SessionScrollbackWriter
    private let checkpointInterval: Duration
    private var fileNameByPaneID: [PaneID: String] = [:]
    private var dirtyPaneIDs = Set<PaneID>()
    private var subscriptions: [(store: WeakWorklaneStore, subscription: WorklaneChangeSubscription)] = []
    private var checkpointTask: Task<Void, Never>?

    private(set) var isEnabled = false

    init(
        archive: SessionScrollbackArchive,
        launchID: String = SessionScrollbackCoordinator.makeLaunchID(),
        checkpointInterval: Duration = SessionScrollbackCoordinator.defaultCheckpointInterval
    ) {
        self.archive = archive
        self.launchID = launchID
        self.writer = SessionScrollbackWriter(archive: archive)
        self.checkpointInterval = checkpointInterval
    }

    convenience init(stateDirectoryURL: URL, launchID: String = SessionScrollbackCoordinator.makeLaunchID()) {
        self.init(archive: SessionScrollbackArchive(stateDirectoryURL: stateDirectoryURL), launchID: launchID)
    }

    static func makeLaunchID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    /// Turning it off forgets every pane and deletes the saved files.
    func setEnabled(_ enabled: Bool, startsCheckpoints: Bool = true) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            if startsCheckpoints {
                startCheckpoints()
            }
        } else {
            checkpointTask?.cancel()
            checkpointTask = nil
            discardAll()
        }
    }

    // MARK: - Restore

    /// Points each restored pane that has a saved file at it, and keeps
    /// those files referenced until the pane captures newer output.
    func prepareRestoredPanes(in state: inout WindowWorkspaceState, from window: WorkspaceRecipe.Window) {
        guard isEnabled else { return }
        let fileNames = Dictionary(
            window.worklanes.flatMap(\.columns).flatMap(\.panes).compactMap { pane in
                pane.scrollbackFile.map { (PaneID(pane.id), $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        guard !fileNames.isEmpty else { return }

        for worklaneIndex in state.worklanes.indices {
            var strip = state.worklanes[worklaneIndex].paneStripState
            for columnIndex in strip.columns.indices {
                for paneIndex in strip.columns[columnIndex].panes.indices {
                    let paneID = strip.columns[columnIndex].panes[paneIndex].id
                    guard let fileName = fileNames[paneID],
                          let path = archive.existingFilePath(forFileName: fileName) else {
                        continue
                    }
                    strip.columns[columnIndex].panes[paneIndex]
                        .sessionRequest.environmentVariables[Self.environmentKey] = path
                    fileNameByPaneID[paneID] = fileName
                }
            }
            state.worklanes[worklaneIndex].paneStripState = strip
        }
    }

    // MARK: - Capture

    func observe(_ store: WorklaneStore) {
        subscriptions.removeAll { $0.store.value == nil }
        guard !subscriptions.contains(where: { $0.store.value === store }) else { return }
        let subscription = store.subscribe { [weak self] change in
            self?.handle(change)
        }
        subscriptions.append((WeakWorklaneStore(value: store), subscription))
    }

    func markDirty(_ paneID: PaneID) {
        guard isEnabled else { return }
        dirtyPaneIDs.insert(paneID)
    }

    /// Captures every live pane, where losing output matters more than the
    /// read cost. The quit path goes through `prepareForSave(_:finalSave:)`.
    func captureAll(synchronously: Bool) {
        capture(sources: sourcesProvider(), onlyDirty: false, synchronously: synchronously)
    }

    /// Periodic crash-safety checkpoint: only panes with activity since the
    /// last capture, or still busy, are read.
    func checkpoint() {
        capture(sources: sourcesProvider(), onlyDirty: true, synchronously: false)
    }

    func capture(sources: [CaptureSource], onlyDirty: Bool, synchronously: Bool) {
        capture(sources: sources, onlyDirty: onlyDirty, synchronously: synchronously, notifiesReferences: !synchronously)
    }

    private func capture(sources: [CaptureSource], onlyDirty: Bool, synchronously: Bool, notifiesReferences: Bool) {
        guard isEnabled else { return }
        let paneCount = sources.reduce(0) { $0 + $1.paneIDs.count }
        let limits = SessionScrollbackText.limits(forPaneCount: paneCount)
        var jobs: [SessionScrollbackWriter.Job] = []
        var didAddReference = false

        for source in sources {
            for paneID in source.paneIDs {
                if onlyDirty, !dirtyPaneIDs.contains(paneID), !source.busyPaneIDs.contains(paneID) {
                    continue
                }
                dirtyPaneIDs.remove(paneID)
                // No runtime yet (deferred start) or a blank screen: keep the
                // file from the previous session, it has not been shown yet.
                guard let raw = source.read(paneID), SessionScrollbackText.hasVisibleContent(raw) else {
                    continue
                }
                let fileName = SessionScrollbackArchive.fileName(forPaneID: paneID.rawValue, launchID: launchID)
                if fileNameByPaneID[paneID] != fileName {
                    didAddReference = true
                }
                fileNameByPaneID[paneID] = fileName
                jobs.append(.init(fileName: fileName, raw: raw, limits: limits))
            }
        }

        if !jobs.isEmpty {
            writer.write(jobs, synchronously: synchronously)
        }
        if didAddReference, notifiesReferences {
            onReferencesChanged?()
        }
    }

    // MARK: - Save

    /// Adds file references to the recipe being saved, forgets panes that
    /// are gone, and deletes every file the recipe no longer references.
    ///
    /// `finalSave` is the quit path: it first captures every pane, and does
    /// all disk work before returning, because the process exits right after
    /// and queued work would be dropped.
    func prepareForSave(_ recipe: WorkspaceRecipe, finalSave: Bool = false) -> WorkspaceRecipe {
        guard isEnabled else { return recipe }
        if finalSave {
            capture(sources: sourcesProvider(), onlyDirty: false, synchronously: true, notifiesReferences: false)
        }
        var recipe = recipe
        var referenced: [PaneID: String] = [:]
        var savedPaneIDs = Set<PaneID>()
        recipe.updatePanes { pane in
            let paneID = PaneID(pane.id)
            savedPaneIDs.insert(paneID)
            pane.scrollbackFile = fileNameByPaneID[paneID]
            referenced[paneID] = pane.scrollbackFile
        }
        fileNameByPaneID = referenced
        dirtyPaneIDs.formIntersection(savedPaneIDs)
        writer.purge(keeping: Set(referenced.values), synchronously: finalSave)
        return recipe
    }

    /// Nothing is being restored any more: drop every file. Pass
    /// `synchronously` on quit, so the files are gone before the app exits.
    func discardAll(synchronously: Bool = false) {
        fileNameByPaneID.removeAll()
        dirtyPaneIDs.removeAll()
        writer.removeAll(synchronously: synchronously)
    }

    func waitForPendingWritesForTesting() {
        writer.waitForPendingOperations()
    }

    var trackedFileNamesForTesting: [PaneID: String] {
        fileNameByPaneID
    }

    // MARK: - Private

    private func handle(_ change: WorklaneChange) {
        switch change {
        case .auxiliaryStateUpdated(_, let paneID, _),
             .volatileAgentTitleUpdated(_, let paneID):
            markDirty(paneID)
        default:
            break
        }
    }

    private func startCheckpoints() {
        checkpointTask?.cancel()
        let interval = checkpointInterval
        checkpointTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.checkpoint()
            }
        }
    }
}

private extension WorkspaceRecipe {
    mutating func updatePanes(_ update: (inout Pane) -> Void) {
        for windowIndex in windows.indices {
            for worklaneIndex in windows[windowIndex].worklanes.indices {
                for columnIndex in windows[windowIndex].worklanes[worklaneIndex].columns.indices {
                    for paneIndex in windows[windowIndex].worklanes[worklaneIndex].columns[columnIndex].panes.indices {
                        update(&windows[windowIndex].worklanes[worklaneIndex].columns[columnIndex].panes[paneIndex])
                    }
                }
            }
        }
    }
}

private struct WeakWorklaneStore {
    weak var value: WorklaneStore?
}

/// Owns the serial queue for every disk operation, so a purge can never
/// overtake a write that was requested before it.
final class SessionScrollbackWriter: @unchecked Sendable {
    struct Job: Sendable {
        var fileName: String
        var raw: String
        var limits: SessionScrollbackText.Limits
    }

    private let archive: SessionScrollbackArchive
    private let queue = DispatchQueue(label: "be.zenjoy.zentty.session-scrollback", qos: .utility)
    /// Queue-confined: content digest of each file as last written.
    private var digestByFileName: [String: String] = [:]

    init(archive: SessionScrollbackArchive) {
        self.archive = archive
    }

    func write(_ jobs: [Job], synchronously: Bool) {
        run(synchronously: synchronously) { [self] in
            for job in jobs {
                writeIfChanged(job)
            }
        }
    }

    func purge(keeping: Set<String>, synchronously: Bool = false) {
        run(synchronously: synchronously) { [self] in
            digestByFileName = digestByFileName.filter { keeping.contains($0.key) }
            archive.purge(keeping: keeping)
        }
    }

    func removeAll(synchronously: Bool = false) {
        run(synchronously: synchronously) { [self] in
            digestByFileName.removeAll()
            archive.removeAll()
        }
    }

    func waitForPendingOperations() {
        queue.sync {}
    }

    private func run(synchronously: Bool, _ work: @escaping @Sendable () -> Void) {
        if synchronously {
            queue.sync(execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    private func writeIfChanged(_ job: Job) {
        let digest = SessionScrollbackArchive.digest(job.raw)
        if digestByFileName[job.fileName] == digest,
           archive.existingFilePath(forFileName: job.fileName) != nil {
            return
        }
        guard let payload = SessionScrollbackText.replayPayload(from: job.raw, limits: job.limits) else {
            return
        }
        do {
            try archive.write(payload, fileName: job.fileName)
            digestByFileName[job.fileName] = digest
        } catch {
            sessionScrollbackLogger.error("Failed to write session scrollback: \(error.localizedDescription, privacy: .public)")
        }
    }
}
