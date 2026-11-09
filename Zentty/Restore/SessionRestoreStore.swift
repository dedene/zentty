import Darwin
import Foundation
import OSLog

private let sessionRestoreLogger = Logger(subsystem: "be.zenjoy.zentty", category: "SessionRestore")

/// The process behind a restore attempt. The start time tells it apart from a
/// later process that was handed the same pid.
struct SessionRestoreProcess: Codable, Equatable, Sendable {
    var pid: Int32
    /// Microseconds since 1970.
    var startTime: Int64

    static let current = running(pid: getpid())

    static func running(pid: Int32) -> SessionRestoreProcess? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_status != UInt32(SZOMB) else {
            return nil
        }
        return SessionRestoreProcess(
            pid: pid,
            startTime: Int64(clamping: info.pbi_start_tvsec) &* 1_000_000 &+ Int64(clamping: info.pbi_start_tvusec)
        )
    }

    var isRunning: Bool {
        Self.running(pid: pid) == self
    }
}

final class SessionRestoreStore: @unchecked Sendable {
    struct LaunchDecision: Equatable, Sendable {
        enum Reason: String, Codable, Equatable, Sendable {
            case normalRestore
            case crashRecovery
        }

        var reason: Reason
        var envelope: SessionRestoreEnvelope
    }

    /// What a launch does about the snapshot on disk.
    enum LaunchAction: Equatable, Sendable {
        case startFresh
        case restore(LaunchDecision)
        /// The snapshot kept killing launches, so it now lives at this URL.
        case setAside(URL)
        /// The snapshot kept killing launches and renaming it failed, so it
        /// stayed where it was. Nothing restores it, and every write to it
        /// retries the rename first and is refused while that keeps failing.
        case setAsideFailed
    }

    /// Whether the snapshot may be written. Only `attemptSetAside` changes it.
    private enum SnapshotAccess {
        case open
        /// A launch owes this snapshot a rename, so it can't be replaced yet.
        case awaitingSetAside
    }

    private struct LifecycleState: Codable, Equatable, Sendable {
        var cleanExit: Bool
        var updatedAt: Date
        /// Restores started since the last save. Older builds ignore it and
        /// write files without it, which reads as zero.
        var incompleteRestoreLaunches: Int?
        /// Who is restoring right now. Absent in files from older builds and
        /// when no restore is open, which leaves the count to stand as it is.
        var restoreOwner: SessionRestoreProcess?
    }

    /// Launches that may die before their first save. The one after them
    /// sets the snapshot aside instead of trying again.
    private static let incompleteRestoreLaunchLimit = 2
    private static let setAsideInfix = ".set-aside-"
    private static let scrollbackFileKey = "scrollbackFile"

    let snapshotURL: URL
    let lifecycleURL: URL
    private let fileManager: FileManager
    private let process: SessionRestoreProcess?
    private let isProcessRunning: @Sendable (SessionRestoreProcess) -> Bool
    /// Held across a rename and across the listing of set-aside scrollback, so
    /// a purge on the scrollback queue sees the snapshot on one side of it.
    private let setAsideLock = NSLock()
    private var snapshotAccess = SnapshotAccess.open
    private var deferredSetAsideHandler: (@Sendable (URL) -> Void)?

    init(
        snapshotURL: URL,
        lifecycleURL: URL,
        fileManager: FileManager = .default,
        process: SessionRestoreProcess? = .current,
        isProcessRunning: @escaping @Sendable (SessionRestoreProcess) -> Bool = { $0.isRunning }
    ) {
        self.snapshotURL = snapshotURL
        self.lifecycleURL = lifecycleURL
        self.fileManager = fileManager
        self.process = process
        self.isProcessRunning = isProcessRunning
    }

    convenience init(stateDirectoryURL: URL) {
        self.init(
            snapshotURL: stateDirectoryURL.appendingPathComponent("restore-snapshot.json"),
            lifecycleURL: stateDirectoryURL.appendingPathComponent("restore-lifecycle.json")
        )
    }

    /// What a launch would restore, without recording anything.
    func prepareForLaunch(restorePreferenceEnabled: Bool) throws -> LaunchDecision? {
        guard let envelope = try loadSnapshot(),
              let reason = Self.restoreReason(
                  lifecycle: lifecycleStateForLaunch(),
                  restorePreferenceEnabled: restorePreferenceEnabled
              ) else {
            return nil
        }

        return LaunchDecision(reason: reason, envelope: envelope)
    }

    /// Moves the lifecycle on for this launch and says what to do with the
    /// snapshot. The attempt is on disk before the snapshot is even decoded, so
    /// a crash anywhere in the restore counts. Crash recovery ignores the
    /// preference, so it counts too: a launch that would restore is limited.
    /// A restore another live instance is still running proves nothing about
    /// the snapshot and isn't this launch's to count, so this launch leaves the
    /// lifecycle alone.
    /// Throws when the snapshot can't be read, which leaves nothing to restore.
    func beginLaunch(restorePreferenceEnabled: Bool) throws -> LaunchAction {
        let lifecycle = lifecycleStateForLaunch()
        let isRestoringElsewhere = isOwnedByAnotherRunningProcess(lifecycle)
        guard fileManager.fileExists(atPath: snapshotURL.path),
              let reason = Self.restoreReason(
                  lifecycle: lifecycle,
                  restorePreferenceEnabled: restorePreferenceEnabled
              ) else {
            if !isRestoringElsewhere {
                recordLaunchStarted(incompleteRestoreLaunches: 0)
            }
            return .startFresh
        }

        if isRestoringElsewhere {
            return try loadSnapshot().map { .restore(LaunchDecision(reason: reason, envelope: $0)) } ?? .startFresh
        }

        let incompleteRestoreLaunches = lifecycle?.incompleteRestoreLaunches ?? 0
        guard incompleteRestoreLaunches < Self.incompleteRestoreLaunchLimit else {
            do {
                // Renamed first: dying here must leave the count for the next try.
                let setAsideURL = try attemptSetAside()
                recordLaunchStarted(incompleteRestoreLaunches: 0)
                return setAsideURL.map(LaunchAction.setAside) ?? .startFresh
            } catch {
                sessionRestoreLogger.error(
                    "Failed to set restore snapshot aside: \(error.localizedDescription, privacy: .public)"
                )
                return .setAsideFailed
            }
        }

        recordLaunchStarted(incompleteRestoreLaunches: incompleteRestoreLaunches + 1)
        guard let envelope = try loadSnapshot() else {
            return .startFresh
        }
        return .restore(LaunchDecision(reason: reason, envelope: envelope))
    }

    /// Called with the new URL when a rename that failed at launch works on a
    /// later try. Runs on whichever queue did the write. Set it before saving.
    func observeDeferredSetAside(_ handler: @escaping @Sendable (URL) -> Void) {
        setAsideLock.withLock { deferredSetAsideHandler = handler }
    }

    /// The scrollback files set-aside snapshots point at, and those of a
    /// snapshot still waiting for its rename. Runs on files set aside because
    /// reopening them failed, so it reads plain JSON instead of decoding them,
    /// and never fails.
    func setAsideScrollbackFileNames() -> Set<String> {
        setAsideLock.withLock {
            let directoryURL = snapshotURL.deletingLastPathComponent()
            var names = ((try? fileManager.contentsOfDirectory(atPath: directoryURL.path)) ?? [])
                .filter(isSetAsideSnapshotName)
            if snapshotAccess == .awaitingSetAside {
                names.append(snapshotURL.lastPathComponent)
            }

            var scrollbackFileNames = Set<String>()
            for name in names {
                do {
                    let data = try Data(contentsOf: directoryURL.appendingPathComponent(name, isDirectory: false))
                    Self.collectScrollbackFileNames(
                        in: try JSONSerialization.jsonObject(with: data),
                        into: &scrollbackFileNames
                    )
                } catch {
                    sessionRestoreLogger.error(
                        "Skipping unreadable set-aside snapshot \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            return scrollbackFileNames
        }
    }

    func markLaunchStarted(incompleteRestoreLaunches: Int = 0) throws {
        try persist(
            LifecycleState(
                cleanExit: false,
                updatedAt: Date(),
                incompleteRestoreLaunches: incompleteRestoreLaunches,
                restoreOwner: incompleteRestoreLaunches > 0 ? process : nil
            ),
            to: lifecycleURL
        )
    }

    func markCleanExit() throws {
        // Left as it is, the next launch still owes the snapshot its rename,
        // and another instance's restore stays open under its owner.
        guard !isAwaitingSetAside, !isOwnedByAnotherRunningProcess(lifecycleStateForLaunch()) else {
            return
        }
        try persist(
            LifecycleState(cleanExit: true, updatedAt: Date()),
            to: lifecycleURL
        )
    }

    /// Throws, writing nothing, while the snapshot can't be set aside.
    func saveSnapshot(_ envelope: SessionRestoreEnvelope) throws {
        try settleOwedSetAside()
        let envelopeToPersist: SessionRestoreEnvelope
        if envelope.reason == .cleanExit {
            envelopeToPersist = envelope.mergingMissingRestoreDrafts(from: previousSnapshotForDraftMerge())
        } else {
            envelopeToPersist = envelope
        }

        try persist(envelopeToPersist, to: snapshotURL)
        clearIncompleteRestoreLaunches()
    }

    /// The `session-scrollback` file names the snapshot's panes point at.
    func referencedScrollbackFileNames() throws -> Set<String> {
        guard let envelope = try loadSnapshot() else { return [] }
        return Set(
            envelope.workspace.windows
                .flatMap(\.worklanes)
                .flatMap(\.allPanes)
                .compactMap(\.scrollbackFile)
        )
    }

    /// Throws, deleting nothing, while the snapshot can't be set aside.
    func deleteSnapshot() throws {
        try settleOwedSetAside()
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return
        }

        try fileManager.removeItem(at: snapshotURL)
        clearIncompleteRestoreLaunches()
    }

    private static func restoreReason(
        lifecycle: LifecycleState?,
        restorePreferenceEnabled: Bool
    ) -> LaunchDecision.Reason? {
        if lifecycle?.cleanExit == false {
            return .crashRecovery
        }
        return restorePreferenceEnabled ? .normalRestore : nil
    }

    /// A lost write costs the limit for one launch, which is better than
    /// giving up the workspace, so it never stops the launch.
    private func recordLaunchStarted(incompleteRestoreLaunches: Int) {
        do {
            try markLaunchStarted(incompleteRestoreLaunches: incompleteRestoreLaunches)
        } catch {
            sessionRestoreLogger.error(
                "Failed to mark restore launch as started: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Files with no owner and owners that died read as they always did: the
    /// attempt is nobody's, so it counts and any save can clear it.
    private func isOwnedByAnotherRunningProcess(_ lifecycle: LifecycleState?) -> Bool {
        guard let owner = lifecycle?.restoreOwner, owner != process else { return false }
        return isProcessRunning(owner)
    }

    /// A save means this launch got past reopening the workspace. It stays
    /// marked as running: a later crash is still a crash to recover from, it
    /// just no longer counts against the snapshot. A restore another live
    /// instance is still running is not this save's to clear.
    private func clearIncompleteRestoreLaunches() {
        guard var lifecycle = lifecycleStateForLaunch(),
              lifecycle.incompleteRestoreLaunches ?? 0 != 0,
              !isOwnedByAnotherRunningProcess(lifecycle) else {
            return
        }

        lifecycle.incompleteRestoreLaunches = 0
        lifecycle.restoreOwner = nil
        lifecycle.updatedAt = Date()
        do {
            try persist(lifecycle, to: lifecycleURL)
        } catch {
            sessionRestoreLogger.error(
                "Failed to clear incomplete restore launches: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private var isAwaitingSetAside: Bool {
        setAsideLock.withLock { snapshotAccess == .awaitingSetAside }
    }

    /// Moves a snapshot the launch failed to set aside out of the way before
    /// anything writes over it. A move that still fails throws, which refuses
    /// the write.
    private func settleOwedSetAside() throws {
        guard isAwaitingSetAside else { return }
        let setAsideURL = try attemptSetAside()
        clearIncompleteRestoreLaunches()
        guard let setAsideURL else { return }
        setAsideLock.withLock { deferredSetAsideHandler }?(setAsideURL)
    }

    /// Returns where the snapshot went, or nil when it is already gone, which
    /// means another instance moved it and there is nothing left to protect.
    private func attemptSetAside() throws -> URL? {
        setAsideLock.lock()
        defer { setAsideLock.unlock() }
        do {
            let setAsideURL = try setAsideSnapshot()
            snapshotAccess = .open
            return setAsideURL
        } catch CocoaError.fileNoSuchFile {
            snapshotAccess = .open
            return nil
        } catch {
            snapshotAccess = .awaitingSetAside
            throw error
        }
    }

    /// Takes the first free number. `moveItem` refuses an existing destination,
    /// so an earlier set-aside file can never be overwritten.
    private func setAsideSnapshot() throws -> URL {
        let stem = snapshotURL.deletingPathExtension().lastPathComponent
        var number = 1
        while true {
            let destinationURL = snapshotURL.deletingLastPathComponent().appendingPathComponent(
                "\(stem)\(Self.setAsideInfix)\(number).\(snapshotURL.pathExtension)",
                isDirectory: false
            )
            do {
                try fileManager.moveItem(at: snapshotURL, to: destinationURL)
                return destinationURL
            } catch CocoaError.fileWriteFileExists {
                number += 1
            }
        }
    }

    private func isSetAsideSnapshotName(_ name: String) -> Bool {
        let stem = snapshotURL.deletingPathExtension().lastPathComponent
        return name.hasPrefix("\(stem)\(Self.setAsideInfix)") && name.hasSuffix(".\(snapshotURL.pathExtension)")
    }

    private static func collectScrollbackFileNames(in value: Any, into fileNames: inout Set<String>) {
        switch value {
        case let object as [String: Any]:
            if let fileName = object[scrollbackFileKey] as? String {
                fileNames.insert(fileName)
            }
            for nestedValue in object.values {
                collectScrollbackFileNames(in: nestedValue, into: &fileNames)
            }
        case let array as [Any]:
            for nestedValue in array {
                collectScrollbackFileNames(in: nestedValue, into: &fileNames)
            }
        default:
            break
        }
    }

    private func loadSnapshot() throws -> SessionRestoreEnvelope? {
        try load(SessionRestoreEnvelope.self, from: snapshotURL)
    }

    /// Old drafts are worth keeping, but never at the cost of the save itself.
    private func previousSnapshotForDraftMerge() -> SessionRestoreEnvelope? {
        do {
            return try loadSnapshot()
        } catch {
            sessionRestoreLogger.error(
                "Replacing unreadable restore snapshot: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Only says how the last run ended, so losing it must not cost the snapshot:
    /// it reads like a missing file, which is a normal restore.
    private func lifecycleStateForLaunch() -> LifecycleState? {
        do {
            return try load(LifecycleState.self, from: lifecycleURL)
        } catch {
            sessionRestoreLogger.error(
                "Ignoring unreadable restore lifecycle: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func load<T: Decodable>(
        _ type: T.Type,
        from url: URL
    ) throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try Self.makeDecoder().decode(type, from: data)
    }

    private func persist<T: Encodable>(
        _ value: T,
        to url: URL
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.makeEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static func makeEncoder() -> JSONEncoder {
        JSONEncoder()
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

enum SessionRestorePersistenceRequest: Sendable {
    case none
    case saveSnapshot(SessionRestoreEnvelope)
    case deleteSnapshot
}

final class SessionRestoreSnapshotPersistence: @unchecked Sendable {
    private let store: SessionRestoreStore
    private let queue = DispatchQueue(label: "be.zenjoy.zentty.session-restore-persistence")
    private var latestAcceptedGeneration: UInt64 = 0

    init(store: SessionRestoreStore) {
        self.store = store
    }

    func persistAsync(_ request: SessionRestorePersistenceRequest, generation: UInt64) {
        queue.async {
            self.persistIfCurrent(request, generation: generation)
        }
    }

    func persistSynchronously(_ request: SessionRestorePersistenceRequest, generation: UInt64) {
        queue.sync {
            guard generation >= self.latestAcceptedGeneration else {
                return
            }
            self.latestAcceptedGeneration = generation
            self.persist(request)
        }
    }

    func waitForPendingOperationsForTesting() {
        queue.sync {}
    }

    private func persistIfCurrent(_ request: SessionRestorePersistenceRequest, generation: UInt64) {
        guard generation >= latestAcceptedGeneration else {
            return
        }

        latestAcceptedGeneration = generation
        persist(request)
    }

    private func persist(_ request: SessionRestorePersistenceRequest) {
        do {
            switch request {
            case .none:
                break
            case .saveSnapshot(let envelope):
                try store.saveSnapshot(envelope)
            case .deleteSnapshot:
                try store.deleteSnapshot()
            }
        } catch {
            sessionRestoreLogger.error("Failed to persist restore snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct SessionRestoreEnvelope: Codable, Equatable, Sendable {
    enum SaveReason: String, Codable, Equatable, Sendable {
        case liveSnapshot
        case cleanExit
    }

    var schemaVersion: Int
    var savedAt: Date
    var reason: SaveReason
    var workspace: WorkspaceRecipe
    var restoreDraftWindows: [SessionRestoreDraftWindow]

    init(
        schemaVersion: Int = 1,
        savedAt: Date = Date(),
        reason: SaveReason = .liveSnapshot,
        workspace: WorkspaceRecipe,
        restoreDraftWindows: [SessionRestoreDraftWindow] = []
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.reason = reason
        self.workspace = workspace
        self.restoreDraftWindows = restoreDraftWindows
    }

    func restoreDraftWindow(forWindowID windowID: String) -> SessionRestoreDraftWindow? {
        restoreDraftWindows.first { $0.windowID == windowID }
    }

    func mergingMissingRestoreDrafts(from previous: SessionRestoreEnvelope?) -> SessionRestoreEnvelope {
        guard let previous else {
            return self
        }

        let validPaneIDsByWindowID = workspace.paneIDsByWindowID()
        guard !validPaneIDsByWindowID.isEmpty else {
            return self
        }

        var mergedRestoreDraftWindows = restoreDraftWindows
        var existingPaneIDsByWindowID: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: mergedRestoreDraftWindows.map { window in
                (window.windowID, Set(window.paneDrafts.map(\.paneID)))
            }
        )

        for previousWindow in previous.restoreDraftWindows {
            guard let validPaneIDs = validPaneIDsByWindowID[previousWindow.windowID] else {
                continue
            }

            let missingPaneDrafts = previousWindow.paneDrafts.filter { draft in
                validPaneIDs.contains(draft.paneID)
                    && !(existingPaneIDsByWindowID[previousWindow.windowID]?.contains(draft.paneID) ?? false)
            }
            guard !missingPaneDrafts.isEmpty else {
                continue
            }

            if let windowIndex = mergedRestoreDraftWindows.firstIndex(where: { $0.windowID == previousWindow.windowID }) {
                mergedRestoreDraftWindows[windowIndex].paneDrafts.append(contentsOf: missingPaneDrafts)
            } else {
                mergedRestoreDraftWindows.append(
                    SessionRestoreDraftWindow(
                        windowID: previousWindow.windowID,
                        paneDrafts: missingPaneDrafts
                    )
                )
            }

            existingPaneIDsByWindowID[previousWindow.windowID, default: []].formUnion(
                missingPaneDrafts.map(\.paneID)
            )
        }

        var merged = self
        merged.restoreDraftWindows = mergedRestoreDraftWindows
        return merged
    }
}

private extension WorkspaceRecipe {
    func paneIDsByWindowID() -> [String: Set<String>] {
        Dictionary(
            uniqueKeysWithValues: windows.map { window in
                let paneIDs = Set(window.worklanes.flatMap { $0.allPanes.map(\.id) })
                return (window.id, paneIDs)
            }
        )
    }
}

struct SessionRestoreDraftWindow: Codable, Equatable, Sendable {
    var windowID: String
    var paneDrafts: [PaneRestoreDraft]

    func draft(forPaneID paneID: PaneID) -> PaneRestoreDraft? {
        paneDrafts.first { $0.paneID == paneID.rawValue }
    }
}

struct PaneRestoreDraft: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case agentResume
    }

    var paneID: String
    var kind: Kind
    var toolName: String
    var sessionID: String
    var workingDirectory: String?
    var trackedPID: Int32
    var agentLaunchSnapshot: AgentLaunchSnapshot? = nil
}

enum SessionRestoreDraftExporter {
    typealias LiveAgentPIDResolver = (_ tool: AgentTool, _ paneRootPID: Int32?) -> Int32?

    static func makeWindowDrafts(
        windowID: WindowID,
        worklanes: [WorklaneState],
        isProcessAlive: (Int32) -> Bool = defaultIsProcessAlive,
        resolveLiveAgentPID: LiveAgentPIDResolver = defaultResolveLiveAgentPID
    ) -> SessionRestoreDraftWindow? {
        let paneDrafts = worklanes.flatMap { worklane in
            // Same set the recipe exporter saves: temporary floats are skipped.
            worklane.persistentPanes.compactMap { pane in
                makePaneDraft(
                    paneID: pane.id,
                    pane: pane,
                    worklane: worklane,
                    isProcessAlive: isProcessAlive,
                    resolveLiveAgentPID: resolveLiveAgentPID
                )
            }
        }

        guard !paneDrafts.isEmpty else {
            return nil
        }

        return SessionRestoreDraftWindow(
            windowID: windowID.rawValue,
            paneDrafts: paneDrafts
        )
    }

    private static func makePaneDraft(
        paneID: PaneID,
        pane: PaneState,
        worklane: WorklaneState,
        isProcessAlive: (Int32) -> Bool,
        resolveLiveAgentPID: LiveAgentPIDResolver
    ) -> PaneRestoreDraft? {
        guard let auxiliary = worklane.auxiliaryStateByPaneID[paneID] else {
            return nil
        }
        guard auxiliary.shellContext?.scope != .remote else {
            return nil
        }
        if let liveDraft = makeLivePaneDraft(
            paneID: paneID,
            pane: pane,
            auxiliary: auxiliary,
            isProcessAlive: isProcessAlive,
            resolveLiveAgentPID: resolveLiveAgentPID
        ) {
            return liveDraft
        }

        guard var restoredDraft = auxiliary.raw.restoredAgentRestoreDraft,
              restoredDraft.paneID == paneID.rawValue,
              AgentResumeCommandBuilder.command(for: restoredDraft) != nil else {
            return nil
        }

        restoredDraft.workingDirectory = workingDirectory(
            agentStatus: auxiliary.agentStatus,
            auxiliary: auxiliary,
            pane: pane,
            restoredDraft: restoredDraft
        )
        return restoredDraft
    }

    static func makeLivePaneDraft(
        paneID: PaneID,
        pane: PaneState,
        auxiliary: PaneAuxiliaryState,
        isProcessAlive: (Int32) -> Bool,
        resolveLiveAgentPID: LiveAgentPIDResolver = defaultResolveLiveAgentPID
    ) -> PaneRestoreDraft? {
        let resolvedWorkingDirectory = workingDirectory(
            agentStatus: auxiliary.agentStatus,
            auxiliary: auxiliary,
            pane: pane,
            restoredDraft: nil
        )

        if let agentStatus = auxiliary.agentStatus,
           let trackedPID = agentStatus.trackedPID,
           isProcessAlive(trackedPID) {
            return makeRestorableDraft(
                paneID: paneID.rawValue,
                tool: agentStatus.tool,
                sessionID: agentStatus.sessionID,
                workingDirectory: resolvedWorkingDirectory,
                trackedPID: trackedPID,
                agentLaunchSnapshot: agentStatus.agentLaunchSnapshot
            )
        }

        if let agentStatus = auxiliary.agentStatus,
           let trackedPID = recoveredTrackedPID(
               for: agentStatus.tool,
               paneRootPID: auxiliary.raw.paneRootPID,
               isProcessAlive: isProcessAlive,
               resolveLiveAgentPID: resolveLiveAgentPID
           ) {
            return makeRestorableDraft(
                paneID: paneID.rawValue,
                tool: agentStatus.tool,
                sessionID: agentStatus.sessionID,
                workingDirectory: resolvedWorkingDirectory,
                trackedPID: trackedPID,
                agentLaunchSnapshot: agentStatus.agentLaunchSnapshot
            )
        }

        guard let hiddenSession = restorableHiddenSession(
            in: auxiliary.agentReducerState,
            workingDirectory: resolvedWorkingDirectory,
            paneRootPID: auxiliary.raw.paneRootPID,
            isProcessAlive: isProcessAlive,
            resolveLiveAgentPID: resolveLiveAgentPID
        ) else {
            return nil
        }

        return makeRestorableDraft(
            paneID: paneID.rawValue,
            tool: hiddenSession.session.tool,
            sessionID: hiddenSession.session.sessionID,
            workingDirectory: resolvedWorkingDirectory,
            trackedPID: hiddenSession.trackedPID,
            agentLaunchSnapshot: hiddenSession.session.agentLaunchSnapshot
        )
    }

    private static func restorableHiddenSession(
        in reducerState: PaneAgentReducerState,
        workingDirectory: String?,
        paneRootPID: Int32?,
        isProcessAlive: (Int32) -> Bool,
        resolveLiveAgentPID: LiveAgentPIDResolver
    ) -> (session: PaneAgentSessionState, trackedPID: Int32)? {
        reducerState.sessionsByID.values
            .compactMap { session -> (session: PaneAgentSessionState, trackedPID: Int32)? in
                let trackedPID: Int32?
                if let sessionPID = session.trackedPID, isProcessAlive(sessionPID) {
                    trackedPID = sessionPID
                } else {
                    trackedPID = recoveredTrackedPID(
                        for: session.tool,
                        paneRootPID: paneRootPID,
                        isProcessAlive: isProcessAlive,
                        resolveLiveAgentPID: resolveLiveAgentPID
                    )
                }
                guard let trackedPID else {
                    return nil
                }

                switch session.state {
                case .starting, .running, .needsInput, .idle:
                    guard makeRestorableDraft(
                        paneID: "",
                        tool: session.tool,
                        sessionID: session.sessionID,
                        workingDirectory: workingDirectory,
                        trackedPID: trackedPID
                    ) != nil else {
                        return nil
                    }
                    return (session, trackedPID)
                case .unresolvedStop:
                    return nil
                }
            }
            .sorted { lhs, rhs in
                let lhsRank = restoreRank(for: lhs.session)
                let rhsRank = restoreRank(for: rhs.session)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.session.updatedAt > rhs.session.updatedAt
            }
            .first
    }

    private static func recoveredTrackedPID(
        for tool: AgentTool,
        paneRootPID: Int32?,
        isProcessAlive: (Int32) -> Bool,
        resolveLiveAgentPID: LiveAgentPIDResolver
    ) -> Int32? {
        guard tool == .hermes,
              let recoveredPID = resolveLiveAgentPID(tool, paneRootPID),
              isProcessAlive(recoveredPID) else {
            return nil
        }
        return recoveredPID
    }

    private enum RestoreIdentityRequirement {
        case sessionID
        case workingDirectory
        case unsupported
    }

    private static func makeRestorableDraft(
        paneID: String,
        tool: AgentTool,
        sessionID rawSessionID: String?,
        workingDirectory rawWorkingDirectory: String?,
        trackedPID: Int32,
        agentLaunchSnapshot: AgentLaunchSnapshot? = nil
    ) -> PaneRestoreDraft? {
        let workingDirectory = trimmed(rawWorkingDirectory)
        let sessionID: String

        switch restoreIdentityRequirement(for: tool) {
        case .sessionID:
            guard let requiredSessionID = trimmed(rawSessionID) else {
                return nil
            }
            sessionID = requiredSessionID
        case .workingDirectory:
            guard workingDirectory != nil else {
                return nil
            }
            sessionID = normalizedOptionalSessionID(rawSessionID, for: tool)
        case .unsupported:
            return nil
        }

        let draft = PaneRestoreDraft(
            paneID: paneID,
            kind: .agentResume,
            toolName: tool.displayName,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            trackedPID: trackedPID,
            agentLaunchSnapshot: agentLaunchSnapshot
        )

        guard AgentResumeCommandBuilder.command(for: draft) != nil else {
            return nil
        }

        return draft
    }

    private static func restoreIdentityRequirement(for tool: AgentTool) -> RestoreIdentityRequirement {
        switch tool {
        case .amp, .claudeCode, .codex, .copilot, .cursor, .droid, .kimi, .openCode, .hermes, .vibe, .devin, .muse:
            return .sessionID
        case .gemini, .pi, .omp, .grok, .agy, .smallHarness:
            return .workingDirectory
        case .custom(let name):
            guard let resume = AgentManifestRegistry.provider()
                .manifest(displayName: name)?.resume
            else {
                return .unsupported
            }
            if resume.command.contains("{sessionId}") {
                return .sessionID
            }
            if resume.command.contains("{workingDirectory}") {
                return .workingDirectory
            }
            return .unsupported
        case .zentty:
            return .unsupported
        }
    }

    private static func normalizedOptionalSessionID(_ rawSessionID: String?, for tool: AgentTool) -> String {
        guard let sessionID = trimmed(rawSessionID) else {
            return ""
        }

        return isPlaceholderSessionID(sessionID, for: tool) ? "" : sessionID
    }

    /// The per-pane id the agent reducer stores until the agent reports a
    /// real one. It names no conversation, so resume and fork both treat it
    /// as missing.
    static func isPlaceholderSessionID(_ sessionID: String, for tool: AgentTool) -> Bool {
        sessionID == "pane-\(tool.displayName.lowercased())"
    }

    private static func restoreRank(for session: PaneAgentSessionState) -> Int {
        switch session.state {
        case .needsInput:
            return 0
        case .running:
            return 1
        case .starting:
            return 2
        case .idle:
            return 3
        case .unresolvedStop:
            return 4
        }
    }

    /// The directory an agent session belongs to. Shared with
    /// `AgentForkCommandBuilder` so a fork starts where a resume would.
    static func workingDirectory(
        agentStatus: PaneAgentStatus?,
        auxiliary: PaneAuxiliaryState,
        pane: PaneState,
        restoredDraft: PaneRestoreDraft?
    ) -> String? {
        trimmed(agentStatus?.workingDirectory)
            ?? trimmed(auxiliary.presentation.cwd)
            ?? trimmed(pane.sessionRequest.workingDirectory)
            ?? trimmed(restoredDraft?.workingDirectory)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }

    static func defaultIsProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else {
            return false
        }

        if kill(pid, 0) == 0 {
            return true
        }

        return errno == EPERM
    }

    private static func defaultResolveLiveAgentPID(tool: AgentTool, paneRootPID: Int32?) -> Int32? {
        guard tool == .hermes,
              let paneRootPID,
              paneRootPID > 0 else {
            return nil
        }

        return HermesProcessResolver.liveHermesDescendantPID(rootPID: paneRootPID)
    }
}

private enum HermesProcessResolver {
    static func liveHermesDescendantPID(rootPID: Int32) -> Int32? {
        DarwinProcessProbe().treePIDs(rootPID: rootPID)
            .filter { $0 != rootPID }
            .first { pid in
                guard let executablePath = DarwinProcessInspector.executablePath(of: pid) else {
                    return false
                }
                return isHermesExecutablePath(executablePath)
            }
    }

    private static func isHermesExecutablePath(_ path: String) -> Bool {
        let normalizedPath = path.lowercased()
        return normalizedPath.contains("/.hermes/hermes-agent/")
            || normalizedPath.hasSuffix("/bin/hermes")
            || normalizedPath.hasSuffix("/hermes")
    }
}

enum AgentResumeCommandBuilder {
    static func command(for draft: PaneRestoreDraft) -> String? {
        guard draft.kind == .agentResume else {
            return nil
        }

        switch AgentTool.resolve(named: draft.toolName) {
        case .amp:
            guard let sessionID = validatedAmpThreadID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            guard let resumeArguments = AmpResumeArgumentSanitizer.sanitizedAmpResumeArguments(
                from: draft.agentLaunchSnapshot?.arguments ?? []
            ) else {
                return nil
            }
            let commandArguments = ["amp", "threads", "continue"] + resumeArguments + [sessionID]
            return commandArguments.map(shellQuotedArgument(_:)).joined(separator: " ")
        case .claudeCode:
            guard let sessionID = validatedClaudeSessionID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            return "claude --resume \(sessionID)"
        case .codex:
            guard let sessionID = validatedCodexSessionID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            return "codex resume \(sessionID)"
        case .openCode:
            guard let sessionID = validatedOpenCodeSessionID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            return "opencode --session \(sessionID)"
        case .copilot:
            guard let sessionID = validatedCopilotSessionID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            return "copilot --resume=\(sessionID)"
        case .cursor:
            guard let sessionID = validatedCursorSessionID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            return "cursor-agent --resume=\(sessionID)"
        case .gemini:
            guard hasWorkingDirectory(draft) else {
                logRejectedWorkingDirectory(for: draft)
                return nil
            }
            return "gemini --resume"
        case .kimi:
            guard let invocation = kimiResumeInvocation(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            switch invocation {
            case .legacy(let sessionID):
                return "kimi -r \(sessionID)"
            case .modern(let sessionID):
                return "kimi -S \(sessionID)"
            }
        case .droid:
            guard let sessionID = validatedDroidSessionID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            return "droid exec -s \(sessionID)"
        case .pi:
            // Pi resumes per-project via `-c` (continue last session). Since pi stores
            // sessions under ~/.pi/agent/sessions/<project>/, we don't need to pass a
            // specific session ID — pi looks up the latest one for this cwd.
            guard hasWorkingDirectory(draft) else {
                logRejectedWorkingDirectory(for: draft)
                return nil
            }
            return "pi -c"
        case .omp:
            guard hasWorkingDirectory(draft) else {
                logRejectedWorkingDirectory(for: draft)
                return nil
            }
            return "omp -c"
        case .smallHarness:
            guard hasWorkingDirectory(draft) else {
                logRejectedWorkingDirectory(for: draft)
                return nil
            }
            return "small-harness --continue"
        case .grok:
            if let sessionID = validatedGrokSessionID(from: draft.sessionID) {
                return "grok --resume \(sessionID)"
            }
            // Fall back to directory-based resume (Grok can resume the last session
            // for the current working directory).
            guard hasWorkingDirectory(draft) else {
                logRejectedWorkingDirectory(for: draft)
                return nil
            }
            return "grok --resume"
        case .agy:
            // A placeholder id means we never received a real
            // `conversation_id` from the agy hook stream; fall back to
            // `--continue` so the user resumes their most recent session
            // rather than seeing `agy --conversation <fake-uuid>` fail.
            if draft.sessionID.isEmpty || draft.sessionID.hasPrefix("zentty-placeholder-") {
                return "agy --continue"
            }
            if let sessionID = validatedAgySessionID(from: draft.sessionID) {
                return "agy --conversation \(sessionID)"
            }
            return nil
        case .hermes:
            guard let sessionID = validatedHermesSessionID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            guard let resumeArguments = sanitizedHermesResumeArguments(
                from: draft.agentLaunchSnapshot?.arguments ?? []
            ) else {
                return nil
            }
            let commandArguments = ["hermes"] + resumeArguments + ["--resume", sessionID]
            let command = commandArguments.map(shellQuotedArgument(_:)).joined(separator: " ")
            if let hermesHome = draft.agentLaunchSnapshot?.environment?["HERMES_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !hermesHome.isEmpty {
                return "env HERMES_HOME=\(shellQuotedArgument(hermesHome)) \(command)"
            }
            return command
        case .vibe:
            guard let sessionID = validatedVibeSessionID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            return "vibe --resume \(sessionID)"
        case .devin:
            // Devin sessions are human-readable slugs (`thorn-angora`),
            // resumable via `devin --resume <slug>`. Without one we can still
            // continue the most recent session via `--continue`.
            if draft.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard hasWorkingDirectory(draft) else {
                    logRejectedWorkingDirectory(for: draft)
                    return nil
                }
                return "devin --continue"
            }
            guard let sessionID = validatedDevinSessionID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            return "devin --resume \(sessionID)"
        case .muse:
            // Muse Code session ids are UUIDs, resumable via `muse resume <uuid>`.
            // Without one, `--last` reopens the newest session in this workspace.
            if draft.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard hasWorkingDirectory(draft) else {
                    logRejectedWorkingDirectory(for: draft)
                    return nil
                }
                return "muse resume --last"
            }
            guard let sessionID = validatedMuseSessionID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            return "muse resume \(sessionID)"
        case .custom(let name):
            guard let resume = AgentManifestRegistry.provider()
                .manifest(displayName: name)?.resume
            else {
                return nil
            }
            return manifestResumeCommand(resume: resume, draft: draft)
        default:
            return nil
        }
    }

    /// Build a resume command from a manifest's `resume.command` template.
    /// `{sessionId}` requires a session id matching `sessionIdPattern` (when
    /// present); `{workingDirectory}` requires the draft's working directory.
    private static func manifestResumeCommand(
        resume: AgentManifest.Resume,
        draft: PaneRestoreDraft
    ) -> String? {
        var command = resume.command
        if command.contains("{sessionId}") {
            guard let sessionID = validatedManifestSessionID(
                draft.sessionID,
                pattern: resume.sessionIdPattern
            ) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            // shellQuotedArgument leaves pattern-validated ids (e.g. ses_abc)
            // untouched but still protects against a manifest whose
            // sessionIdPattern admits shell-unsafe characters.
            command = command.replacingOccurrences(
                of: "{sessionId}",
                with: shellQuotedArgument(sessionID)
            )
        }
        if command.contains("{workingDirectory}") {
            guard let workingDirectory = draft.workingDirectory?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !workingDirectory.isEmpty
            else {
                logRejectedWorkingDirectory(for: draft)
                return nil
            }
            command = command.replacingOccurrences(
                of: "{workingDirectory}",
                with: shellQuotedArgument(workingDirectory)
            )
        }
        return command
    }

    // Validators and shell quoting below without `private` are shared with
    // `AgentForkCommandBuilder`, so a fork accepts exactly the ids a resume
    // would.
    static func validatedManifestSessionID(
        _ sessionID: String,
        pattern: String?
    ) -> String? {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let pattern else {
            return trimmed
        }
        guard let regex = try? NSRegularExpression(pattern: "^(?:\(pattern))$"),
              regex.firstMatch(
                  in: trimmed,
                  range: NSRange(trimmed.startIndex..., in: trimmed)
              ) != nil
        else {
            return nil
        }
        return trimmed
    }

    static func validatedClaudeSessionID(from sessionID: String) -> String? {
        guard let uuid = UUID(uuidString: sessionID) else {
            return nil
        }
        return uuid.uuidString.lowercased()
    }

    static func validatedCodexSessionID(from sessionID: String) -> String? {
        if let uuid = UUID(uuidString: sessionID) {
            return uuid.uuidString.lowercased()
        }

        let pattern = "^[A-Za-z0-9][A-Za-z0-9_-]*$"
        guard sessionID.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }

        return sessionID
    }

    static func validatedOpenCodeSessionID(from sessionID: String) -> String? {
        let pattern = #"^ses_[A-Za-z0-9]+$"#
        guard sessionID.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }

        return sessionID
    }

    private static func validatedCopilotSessionID(from sessionID: String) -> String? {
        guard let uuid = UUID(uuidString: sessionID) else {
            return nil
        }
        return uuid.uuidString.lowercased()
    }

    private static func validatedCursorSessionID(from sessionID: String) -> String? {
        guard let uuid = UUID(uuidString: sessionID) else {
            return nil
        }
        return uuid.uuidString.lowercased()
    }

    static func validatedGrokSessionID(from sessionID: String) -> String? {
        // Grok Build sessions are typically UUIDs. We also accept reasonable
        // alphanumeric session identifiers (Grok may use short IDs in some modes).
        if let uuid = UUID(uuidString: sessionID) {
            return uuid.uuidString.lowercased()
        }

        let pattern = "^[A-Za-z0-9][A-Za-z0-9_-]{3,}$"
        guard sessionID.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return sessionID
    }

    private static func validatedVibeSessionID(from sessionID: String) -> String? {
        // Mistral Vibe session IDs are opaque; accept UUIDs and reasonable
        // alphanumeric identifiers, rejecting anything shell-unsafe so the id
        // can be interpolated into `vibe --resume <id>` directly.
        if let uuid = UUID(uuidString: sessionID) {
            return uuid.uuidString.lowercased()
        }

        let pattern = "^[A-Za-z0-9][A-Za-z0-9_-]{3,}$"
        guard sessionID.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return sessionID
    }

    private static func validatedDevinSessionID(from sessionID: String) -> String? {
        // Devin session IDs are human-readable word slugs (`thorn-angora`);
        // accept letters, digits and dashes only so the slug is safe to
        // interpolate into `devin --resume <slug>` unquoted.
        let pattern = "^[a-z0-9][a-z0-9-]*$"
        guard sessionID.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return sessionID
    }

    private enum KimiResumeInvocation {
        case legacy(sessionID: String)
        case modern(sessionID: String)
    }

    /// Legacy Kimi uses bare UUIDs; modern kimi-code uses `session_<uuid>`.
    private static func kimiResumeInvocation(from sessionID: String) -> KimiResumeInvocation? {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedSessionID.hasPrefix("session_") {
            let uuidPart = String(trimmedSessionID.dropFirst("session_".count))
            guard UUID(uuidString: uuidPart) != nil else {
                return nil
            }
            return .modern(sessionID: "session_" + uuidPart.lowercased())
        }

        guard let uuid = UUID(uuidString: trimmedSessionID) else {
            return nil
        }
        return .legacy(sessionID: uuid.uuidString.lowercased())
    }

    private static func validatedMuseSessionID(from sessionID: String) -> String? {
        guard let uuid = UUID(uuidString: sessionID) else {
            return nil
        }
        return uuid.uuidString.lowercased()
    }

    static func validatedDroidSessionID(from sessionID: String) -> String? {
        // Droid session IDs are opaque strings; validate only that they are
        // non-empty and contain no shell metacharacters or whitespace so the
        // restore command remains a single safe argument.
        let pattern = "^[A-Za-z0-9_.:-]+$"
        guard sessionID.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return sessionID
    }

    private static func validatedAmpThreadID(from sessionID: String) -> String? {
        let pattern = #"^T-[A-Za-z0-9_-]+$"#
        guard sessionID.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return sessionID
    }

    private static func validatedAgySessionID(from sessionID: String) -> String? {
        // Antigravity session IDs are typical alphanumeric identifiers.
        // The `zentty-placeholder-` prefix is what the launch bootstrap
        // injects before the first real `conversation_id` arrives; it
        // must never reach `agy --conversation`.
        if sessionID.hasPrefix("zentty-placeholder-") {
            return nil
        }
        let pattern = "^[A-Za-z0-9_-]+$"
        guard sessionID.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return sessionID
    }

    private static func validatedHermesSessionID(from sessionID: String) -> String? {
        guard !sessionID.hasPrefix("zentty-hermes-placeholder-") else {
            return nil
        }
        let pattern = "^[A-Za-z0-9_.:-]+$"
        guard sessionID.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return sessionID
    }

    private static func sanitizedHermesResumeArguments(from arguments: [String]) -> [String]? {
        let oneShotFlags: Set<String> = ["--oneshot", "-z", "--query", "-q", "--quiet", "-Q"]
        for argument in arguments {
            let option = argument.hasPrefix("--")
                ? (argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument)
                : argument
            if oneShotFlags.contains(option) {
                return nil
            }
        }

        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if index == 0, argument == "chat" {
                index += 1
                continue
            }
            if argument == "--resume" || argument == "-r" {
                index += 2
                continue
            }
            if argument.hasPrefix("--resume=") {
                index += 1
                continue
            }
            result.append(argument)
            index += 1
        }
        return result
    }

    static func shellQuotedArgument(_ argument: String) -> String {
        if argument.range(of: #"^[A-Za-z0-9_./:=+-]+$"#, options: .regularExpression) != nil {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func hasWorkingDirectory(_ draft: PaneRestoreDraft) -> Bool {
        guard let workingDirectory = draft.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }

        return !workingDirectory.isEmpty
    }

    private static func logRejectedSessionID(for draft: PaneRestoreDraft) {
        let preview = String(draft.sessionID.prefix(32))
        sessionRestoreLogger.error(
            "Skipping restore draft for tool \(draft.toolName, privacy: .public) because the session identifier was invalid: \(preview, privacy: .public)"
        )
    }

    private static func logRejectedWorkingDirectory(for draft: PaneRestoreDraft) {
        sessionRestoreLogger.error(
            "Skipping restore draft for tool \(draft.toolName, privacy: .public) because the working directory was unavailable"
        )
    }
}
