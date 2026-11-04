import Foundation

/// One FSEvents root: the path the stream watches (`FileEventStream.canonicalPath`, realpath
/// with `/private` kept) and the same folder as its source spells it.
struct AgentHistoryWatchRoot: Equatable, Sendable {
    let canonicalPath: String
    let sourcePath: String
    let sourceID: Int64
}

/// Keeping the index fresh between reconciles. Indexer queue only.
///
/// - One `FileEventStream` over the watch paths of every source that exist right now. It is
///   rebuilt after reconciles when that set changed, and on `rootChanged`.
/// - A file event maps to the source whose watch root is the longest prefix of its path, then
///   through `eventTarget(forCanonicalPath:)`: a unit goes to the live lane; a database is
///   polled at most once per `schedule.dbPollMinInterval` (leading edge, one trailing poll).
///   A unit the indexer has not discovered yet triggers one discovery of its source; keys that
///   discovery does not list (child transcripts) are not looked up again for
///   `unknownUnitRecheckInterval`.
/// - `mustScanSubDirs` / `rootChanged` reconcile the owning source; dropped events and
///   mount/unmount reconcile every source. Event-driven reconciles are never "full": they
///   neither confirm a missing root nor a deferred mass deletion.
/// - A full reconcile every `schedule.interval` (wall-clock timer, 60 s leeway) and
///   `schedule.wakeDelay` after a wake from sleep.
extension AgentHistoryIndexer {
    /// How long a unit key that discovery did not list is ignored by later events.
    static let unknownUnitRecheckInterval: TimeInterval = 10
    static let periodicReconcileLeeway = DispatchTimeInterval.seconds(60)

    // MARK: - Lifecycle

    /// Starts the stream, the periodic reconcile and wake observation. Runs inside `start`, so
    /// the stream is watching before any later queue work (a test's drain included).
    func startFreshness() {
        refreshFileEventStream(force: false)
        armPeriodicReconcile()
        let eventQueue = queue
        systemConditions.startObservingWake { [weak self] in
            eventQueue.async {
                self?.systemDidWake()
            }
        }
    }

    /// Stops the stream and the timer and forgets pending polls. Safe to call twice.
    func stopFreshness() {
        fileEventStream?.stop()
        fileEventStream = nil
        watchRoots = []
        periodicTimer?.cancel()
        periodicTimer = nil
        lastDatabasePollAt = [:]
        pendingDatabasePolls = []
        unknownEventUnitsCheckedAt = [:]
    }

    /// Drops the event bookkeeping of a source that was turned off.
    func forgetEventState(sourceID: Int64) {
        lastDatabasePollAt = lastDatabasePollAt.filter { $0.key.sourceID != sourceID }
        pendingDatabasePolls = pendingDatabasePolls.filter { $0.sourceID != sourceID }
        unknownEventUnitsCheckedAt = unknownEventUnitsCheckedAt.filter { $0.key.sourceID != sourceID }
    }

    /// Reconciles, then refreshes state, publishes and resumes the step loop.
    func reconcileAndContinue(sourceIDs: [Int64], isFull: Bool) {
        reconcile(sourceIDs: sourceIDs, isFull: isFull)
        updateProgressState()
        publish()
        scheduleStep()
    }

    // MARK: - Stream

    /// Rebuilds the watch roots on a later queue turn (never from inside an FSEvents callback).
    /// `force` restarts the stream even when the watched paths did not change.
    func scheduleStreamRefresh(force: Bool = false) {
        streamRestartRequested = streamRestartRequested || force
        guard lifecycle == .running, !streamRefreshScheduled else {
            return
        }
        streamRefreshScheduled = true
        queue.async { [self] in
            streamRefreshScheduled = false
            let force = streamRestartRequested
            streamRestartRequested = false
            refreshFileEventStream(force: force)
        }
    }

    func refreshFileEventStream(force: Bool) {
        guard lifecycle == .running, !cancellation.isSet else {
            return
        }
        let roots = currentWatchRoots()
        watchRoots = roots
        var seen = Set<String>()
        let paths = roots.map(\.canonicalPath).filter { seen.insert($0).inserted }
        if !force, let stream = fileEventStream, Set(stream.watchedPaths) == seen {
            return
        }
        fileEventStream?.stop()
        fileEventStream = nil
        guard !paths.isEmpty else {
            AgentHistoryLog.indexer.info("Agent History has no existing roots to watch")
            return
        }
        let stream = FileEventStream(paths: paths, latency: configuration.fileEventLatency, queue: queue) { [weak self] events in
            self?.handleFileEvents(events)
        }
        if stream.start() {
            fileEventStream = stream
            AgentHistoryLog.indexer.info("Agent History watching roots=\(paths.count, privacy: .public)")
        } else {
            AgentHistoryLog.indexer.error("Agent History could not watch roots=\(paths.count, privacy: .public); periodic reconcile only")
        }
    }

    /// Watch paths that exist, longest canonical path first (so the longest prefix wins).
    func currentWatchRoots() -> [AgentHistoryWatchRoot] {
        var roots: [AgentHistoryWatchRoot] = []
        for id in sourceOrder {
            guard let sourceState = sourceStates[id] else {
                continue
            }
            for path in sourceState.source.watchPaths where path.hasPrefix("/") {
                guard FileManager.default.fileExists(atPath: path) else {
                    continue
                }
                roots.append(AgentHistoryWatchRoot(
                    canonicalPath: FileEventStream.canonicalPath(path),
                    sourcePath: Self.strippingTrailingSlash(path),
                    sourceID: id
                ))
            }
        }
        return roots.enumerated().sorted { lhs, rhs in
            lhs.element.canonicalPath.count != rhs.element.canonicalPath.count
                ? lhs.element.canonicalPath.count > rhs.element.canonicalPath.count
                : lhs.offset < rhs.offset
        }.map(\.element)
    }

    // MARK: - Events

    func handleFileEvents(_ events: [FileEvent]) {
        guard lifecycle == .running, !cancellation.isSet, !events.isEmpty else {
            return
        }
        var reconcileAll = false
        var rescan: [Int64] = []
        var restartStream = false
        var targets: [(ref: AgentHistoryUnitRef, isDatabase: Bool)] = []
        var seenTargets = Set<AgentHistoryUnitRef>()

        for event in events {
            let flags = event.flags
            if flags.isDropped || flags.contains(.mount) || flags.contains(.unmount) {
                reconcileAll = true
                continue
            }
            if flags.contains(.mustScanSubDirs) || flags.contains(.rootChanged) {
                let owners = owningSourceIDs(of: event.path)
                if owners.isEmpty {
                    reconcileAll = true
                }
                for id in owners where !rescan.contains(id) {
                    rescan.append(id)
                }
                restartStream = restartStream || flags.contains(.rootChanged)
                continue
            }
            guard let match = eventTarget(forEventPath: event.path) else {
                continue
            }
            let ref: AgentHistoryUnitRef
            let isDatabase: Bool
            switch match.target {
            case .unit(let key):
                ref = AgentHistoryUnitRef(sourceID: match.sourceID, unitKey: key)
                isDatabase = false
            case .database(let key):
                ref = AgentHistoryUnitRef(sourceID: match.sourceID, unitKey: key)
                isDatabase = true
            }
            if seenTargets.insert(ref).inserted {
                targets.append((ref, isDatabase))
            }
        }

        if reconcileAll || !rescan.isEmpty {
            let ids = reconcileAll ? sourceOrder : sourceOrder.filter(rescan.contains)
            AgentHistoryLog.indexer.info(
                "Agent History rescanning after file events sources=\(ids.count, privacy: .public) all=\(reconcileAll, privacy: .public)"
            )
            reconcile(sourceIDs: ids, isFull: false)
        }
        dispatchEventTargets(targets)
        if restartStream {
            scheduleStreamRefresh(force: true)
        }
        updateProgressState()
        publish()
        scheduleStep()
    }

    /// Known units go live (databases through the poll throttle); unknown ones cost one
    /// discovery per source, then are queued if discovery lists them.
    func dispatchEventTargets(_ targets: [(ref: AgentHistoryUnitRef, isDatabase: Bool)]) {
        var unknown: [Int64: [(ref: AgentHistoryUnitRef, isDatabase: Bool)]] = [:]
        var unknownOrder: [Int64] = []
        for target in targets {
            guard let sourceState = sourceStates[target.ref.sourceID] else {
                continue
            }
            if sourceState.units[target.ref.unitKey] != nil {
                enqueueEventTarget(target.ref, isDatabase: target.isDatabase)
                continue
            }
            if unknown[target.ref.sourceID] == nil {
                unknownOrder.append(target.ref.sourceID)
            }
            unknown[target.ref.sourceID, default: []].append(target)
        }
        guard !unknown.isEmpty else {
            return
        }
        let current = now()
        pruneUnknownEventUnits(now: current)
        for sourceID in unknownOrder {
            guard let sourceState = sourceStates[sourceID] else {
                continue
            }
            let due = (unknown[sourceID] ?? []).filter { target in
                guard let checkedAt = unknownEventUnitsCheckedAt[target.ref] else {
                    return true
                }
                return current.timeIntervalSince(checkedAt) >= Self.unknownUnitRecheckInterval
            }
            guard !due.isEmpty, discover(sourceState) else {
                continue
            }
            for target in due {
                if sourceState.units[target.ref.unitKey] != nil {
                    unknownEventUnitsCheckedAt[target.ref] = nil
                    enqueueEventTarget(target.ref, isDatabase: target.isDatabase)
                } else {
                    unknownEventUnitsCheckedAt[target.ref] = current
                }
            }
        }
    }

    func enqueueEventTarget(_ ref: AgentHistoryUnitRef, isDatabase: Bool) {
        if isDatabase {
            requestDatabasePoll(ref)
        } else {
            workQueue.enqueueLive(ref)
        }
    }

    /// Leading edge: the first change (or one after a quiet `dbPollMinInterval`) polls now;
    /// changes inside the window coalesce into one trailing poll at its end.
    func requestDatabasePoll(_ ref: AgentHistoryUnitRef) {
        let current = now()
        let pollAt = schedule.nextDatabasePoll(lastPollAt: lastDatabasePollAt[ref], now: current)
        guard pollAt > current else {
            lastDatabasePollAt[ref] = current
            workQueue.enqueueLive(ref)
            return
        }
        guard pendingDatabasePolls.insert(ref).inserted else {
            return
        }
        queue.asyncAfter(deadline: .now() + pollAt.timeIntervalSince(current)) { [weak self] in
            guard let self, pendingDatabasePolls.remove(ref) != nil else {
                return
            }
            guard lifecycle == .running, !cancellation.isSet, sourceStates[ref.sourceID] != nil else {
                return
            }
            lastDatabasePollAt[ref] = now()
            workQueue.enqueueLive(ref)
            updateProgressState()
            scheduleStep()
        }
    }

    /// The source a path belongs to and what it means to it. Tries the path as FSEvents
    /// reported it, then re-spelled under the source's own watch path (a symlinked root).
    func eventTarget(forEventPath path: String) -> (sourceID: Int64, target: AgentHistoryEventTarget)? {
        for root in watchRoots where AgentHistoryPath.isCanonicalPath(path, insideCanonical: root.canonicalPath) {
            guard let sourceState = sourceStates[root.sourceID] else {
                continue
            }
            if let target = sourceState.source.eventTarget(forCanonicalPath: path) {
                return (root.sourceID, target)
            }
            let respelled = Self.respell(path, from: root.canonicalPath, to: root.sourcePath)
            if respelled != path, let target = sourceState.source.eventTarget(forCanonicalPath: respelled) {
                return (root.sourceID, target)
            }
        }
        return nil
    }

    /// Sources whose watch root contains the path, or lies under it (an ancestor was renamed).
    func owningSourceIDs(of path: String) -> [Int64] {
        var owners: [Int64] = []
        for root in watchRoots where !owners.contains(root.sourceID) {
            if AgentHistoryPath.isCanonicalPath(path, insideCanonical: root.canonicalPath)
                || AgentHistoryPath.isCanonicalPath(root.canonicalPath, insideCanonical: path) {
                owners.append(root.sourceID)
            }
        }
        return owners
    }

    func pruneUnknownEventUnits(now current: Date) {
        guard unknownEventUnitsCheckedAt.count > 512 else {
            return
        }
        unknownEventUnitsCheckedAt = unknownEventUnitsCheckedAt.filter {
            current.timeIntervalSince($0.value) < Self.unknownUnitRecheckInterval
        }
    }

    // MARK: - Periodic and wake reconciles

    /// Arms the one-shot wall-clock timer for the next due full reconcile.
    func armPeriodicReconcile() {
        guard lifecycle == .running else {
            return
        }
        let delay: TimeInterval
        if let last = schedule.lastReconcileAt {
            delay = max(1, last.addingTimeInterval(schedule.interval).timeIntervalSince(now()))
        } else {
            delay = schedule.interval
        }
        if let periodicTimer {
            periodicTimer.schedule(wallDeadline: .now() + delay, repeating: .never, leeway: Self.periodicReconcileLeeway)
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            self?.periodicReconcileFired()
        }
        timer.schedule(wallDeadline: .now() + delay, repeating: .never, leeway: Self.periodicReconcileLeeway)
        timer.resume()
        periodicTimer = timer
    }

    func periodicReconcileFired() {
        guard lifecycle == .running, !cancellation.isSet else {
            return
        }
        if schedule.isPeriodicReconcileDue(now: now()) {
            reconcileAndContinue(sourceIDs: sourceOrder, isFull: true)
        }
        armPeriodicReconcile()
    }

    /// Volumes and network settle for `schedule.wakeDelay`, then one full reconcile.
    func systemDidWake() {
        guard lifecycle == .running, !wakeReconcileScheduled else {
            return
        }
        wakeReconcileScheduled = true
        queue.asyncAfter(wallDeadline: .now() + schedule.wakeDelay) { [weak self] in
            guard let self else {
                return
            }
            wakeReconcileScheduled = false
            guard lifecycle == .running, !cancellation.isSet else {
                return
            }
            AgentHistoryLog.indexer.info("Agent History reconciling after wake")
            reconcileAndContinue(sourceIDs: sourceOrder, isFull: true)
            armPeriodicReconcile()
        }
    }

    // MARK: - Helpers

    static func respell(_ path: String, from canonicalRoot: String, to sourceRoot: String) -> String {
        guard canonicalRoot != sourceRoot else {
            return path
        }
        let rest = path.dropFirst(canonicalRoot.count)
        if sourceRoot == "/" {
            return rest.hasPrefix("/") ? String(rest) : "/" + rest
        }
        if canonicalRoot == "/" {
            return sourceRoot + "/" + rest
        }
        return sourceRoot + rest
    }

    static func strippingTrailingSlash(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
