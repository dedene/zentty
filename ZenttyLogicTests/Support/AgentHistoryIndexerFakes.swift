import Foundation
import XCTest
@testable import Zentty

/// One scripted session of a fake unit.
struct FakeHistorySession: Sendable {
    var nativeID: String
    var title: String?
    var cwd: String?
    var parentNativeID: String?
    /// Message texts; roles alternate user/agent starting with user. `atMs` = base + index.
    var messages: [String]
    var baseAtMs: Int64 = 1_793_000_000_000
    /// Reported in `diagnostics.skippedSessions` instead of being delivered.
    var skipReason: AgentHistorySkipReason?
}

/// One scripted unit. Single-session units page through messages (`limits.messages` per batch,
/// byte offset = message index); database units deliver all sessions in one batch.
struct FakeHistoryUnit: Sendable {
    var key: String
    var kind: AgentHistoryUnit.Kind = .jsonl
    var ino: Int64 = 1
    var mtimeNs: Int64 = 1
    var sessions: [FakeHistorySession]
    var problem: AgentHistorySourceProblem?

    var messageCount: Int { sessions.first?.messages.count ?? 0 }

    var identity: AgentHistoryFileIdentity {
        AgentHistoryFileIdentity(dev: 1, ino: ino, size: Int64(kind == .database ? 0 : messageCount), mtimeNs: mtimeNs)
    }

    var unit: AgentHistoryUnit {
        AgentHistoryUnit(
            key: key,
            path: "/fake/\(key)",
            kind: kind,
            identity: identity,
            nativeSessionID: kind == .database ? nil : sessions.first?.nativeID
        )
    }

    static func single(
        _ nativeID: String,
        messages: [String] = ["hello", "hi there"],
        title: String? = nil,
        cwd: String? = "/work/project",
        parent: String? = nil,
        mtimeNs: Int64 = 1,
        ino: Int64 = 1
    ) -> FakeHistoryUnit {
        FakeHistoryUnit(
            key: nativeID,
            ino: ino,
            mtimeNs: mtimeNs,
            sessions: [FakeHistorySession(nativeID: nativeID, title: title ?? "Prompt \(nativeID)", cwd: cwd,
                                          parentNativeID: parent, messages: messages)]
        )
    }
}

/// An in-memory `AgentHistorySource` with scripted units, change overrides, an ingest hook and
/// a call log. Thread-safe: the indexer calls it on its queue while tests mutate it.
final class FakeHistorySource: AgentHistorySource, @unchecked Sendable {
    typealias IngestHook = @Sendable (_ unitKey: String, _ cursor: AgentHistoryCursor?, _ context: AgentHistoryIngestContext) throws -> Void

    let agent: AgentHistoryAgent
    let root: AgentHistorySourceRoot
    let adapterVersion: Int
    var watchPaths: [String] { [root.path] }

    private let lock = NSLock()
    private var units: [String: FakeHistoryUnit] = [:]
    private var overrides: [String: AgentHistoryUnitChange] = [:]
    private var hook: IngestHook?
    private var ingested: [String] = []
    private var discoveries = 0
    private var existingIDs: Set<String>?
    private var discoveryError: (any Error)?
    private var eventTargets: [String: AgentHistoryEventTarget] = [:]

    init(agent: AgentHistoryAgent = .claude, rootPath: String = "/fake/root", adapterVersion: Int = 1) {
        self.agent = agent
        self.root = AgentHistorySourceRoot(agent: agent, path: rootPath, isDefault: true)
        self.adapterVersion = adapterVersion
    }

    // MARK: Scripting

    func setUnits(_ newUnits: [FakeHistoryUnit]) {
        withLock { for unit in newUnits { units[unit.key] = unit } }
    }

    func removeUnit(_ key: String) {
        withLock { units[key] = nil }
    }

    func overrideChange(_ key: String, _ change: AgentHistoryUnitChange?) {
        withLock { overrides[key] = change }
    }

    func setIngestHook(_ hook: IngestHook?) {
        withLock { self.hook = hook }
    }

    /// What `existingNativeIDs()` reports; nil (the default) behaves like a file source.
    func setExistingNativeIDs(_ ids: Set<String>?) {
        withLock { existingIDs = ids }
    }

    /// Makes `discoverUnits()` throw until cleared.
    func setDiscoveryError(_ error: (any Error)?) {
        withLock { discoveryError = error }
    }

    /// What `eventTarget(forCanonicalPath:)` answers for an exact path; other paths are noise.
    func setEventTarget(_ target: AgentHistoryEventTarget?, forPath path: String) {
        withLock { eventTargets[path] = target }
    }

    var ingestedKeys: [String] { withLock { ingested } }
    var discoverCount: Int { withLock { discoveries } }

    // MARK: AgentHistorySource

    func discoverUnits() throws -> [AgentHistoryUnit] {
        try withLock {
            discoveries += 1
            if let discoveryError {
                throw discoveryError
            }
            return units.values.map(\.unit).sorted { $0.key < $1.key }
        }
    }

    func existingNativeIDs() throws -> Set<String>? {
        withLock { existingIDs }
    }

    func eventTarget(forCanonicalPath path: String) -> AgentHistoryEventTarget? {
        withLock { eventTargets[path] }
    }

    func refreshUnit(_ unit: AgentHistoryUnit) -> AgentHistoryUnit {
        withLock {
            units[unit.key]?.unit ?? AgentHistoryUnit(
                key: unit.key, path: unit.path, kind: unit.kind, identity: nil, nativeSessionID: unit.nativeSessionID
            )
        }
    }

    func classifyChange(unit: AgentHistoryUnit, cursor: AgentHistoryCursor?) -> AgentHistoryUnitChange {
        if let override = withLock({ overrides[unit.key] }) {
            return override
        }
        guard let current = unit.identity else {
            return cursor == nil ? .new : .missing
        }
        guard let cursor else {
            return .new
        }
        if unit.kind == .database {
            return .append(fromOffset: 0, nextSeq: 0)
        }
        if cursor.isRejected {
            return cursor.identity?.ino == current.ino ? .unchanged : .new
        }
        guard let stored = cursor.identity, stored.ino == current.ino, current.size >= cursor.byteOffset else {
            return .rewrite
        }
        if stored == current, cursor.byteOffset >= current.size {
            return .unchanged
        }
        return .append(fromOffset: cursor.byteOffset, nextSeq: cursor.nextSeq)
    }

    func ingest(
        unit: AgentHistoryUnit,
        cursor: AgentHistoryCursor?,
        mode: AgentHistoryIngestMode,
        context: AgentHistoryIngestContext
    ) throws -> AgentHistoryIngestBatch {
        let (scripted, hook) = withLock { () -> (FakeHistoryUnit?, IngestHook?) in
            ingested.append(unit.key)
            return (units[unit.key], self.hook)
        }
        try hook?(unit.key, cursor, context)
        guard let scripted else {
            throw POSIXError(.ENOENT)
        }
        var batch = AgentHistoryIngestBatch(cursor: cursor ?? AgentHistoryCursor(sourceID: 0, unitKey: unit.key), hasMore: false)
        batch.problem = scripted.problem
        let start: Int
        switch mode {
        case .fromStart: start = 0
        case let .fromOffset(offset, _): start = Int(offset)
        }

        if scripted.kind == .database {
            for session in scripted.sessions {
                deliver(session, from: 0, to: session.messages.count, into: &batch, context: context)
            }
            batch.cursor = batch.cursor.advanced(identity: scripted.identity, byteOffset: 0, nextSeq: 0,
                                                 fingerprint: nil, adapterState: Data([UInt8(truncatingIfNeeded: batch.sessions.count)]))
            return batch
        }

        guard let session = scripted.sessions.first else {
            return batch
        }
        let end = min(session.messages.count, start + context.limits.messages)
        let delivered = deliver(session, from: start, to: end, into: &batch, context: context)
        let offset = delivered ? end : start
        batch.hasMore = delivered && end < session.messages.count
        batch.cursor = batch.cursor.advanced(identity: scripted.identity, byteOffset: Int64(offset), nextSeq: offset,
                                             fingerprint: nil, adapterState: nil)
        return batch
    }

    func estimatedSessionCount() -> Int? {
        withLock { units.count }
    }

    // MARK: Helpers

    /// Adds one session's slice to the batch; false when the session was skipped or rejected.
    @discardableResult
    private func deliver(
        _ session: FakeHistorySession,
        from start: Int,
        to end: Int,
        into batch: inout AgentHistoryIngestBatch,
        context: AgentHistoryIngestContext
    ) -> Bool {
        if let reason = session.skipReason {
            batch.diagnostics.skippedSessions[session.nativeID] = reason
            return false
        }
        let decision = context.admission.decide(agent: agent, nativeID: session.nativeID, cwd: session.cwd)
        guard decision == .admit else {
            batch.rejected[session.nativeID] = decision
            return false
        }
        var draft = AgentHistorySessionDraft(nativeID: session.nativeID)
        draft.title = session.title
        draft.titleKind = .firstPrompt
        draft.cwd = session.cwd
        draft.parentNativeID = session.parentNativeID
        if start < end {
            draft.createdAtMs = session.baseAtMs + Int64(start)
            draft.updatedAtMs = session.baseAtMs + Int64(end - 1)
        }
        batch.sessions.append(draft)
        for index in start..<end {
            batch.messages.append(AgentHistoryFixtures.message(
                session.nativeID, seq: index, role: index.isMultiple(of: 2) ? .user : .agent,
                atMs: session.baseAtMs + Int64(index), text: session.messages[index]
            ))
        }
        if start == 0 {
            batch.replaceContentOf.insert(session.nativeID)
        }
        return true
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Scriptable pause conditions.
final class FakeSystemConditions: AgentHistorySystemConditions, @unchecked Sendable {
    private let lock = NSLock()
    private var reason: AgentHistoryPauseReason?
    private var handler: (@Sendable () -> Void)?
    private var wakeHandler: (@Sendable () -> Void)?

    var pauseReason: AgentHistoryPauseReason? {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }

    func setPauseReason(_ next: AgentHistoryPauseReason?) {
        lock.lock()
        reason = next
        let handler = self.handler
        lock.unlock()
        handler?()
    }

    func startObserving(_ onChange: @escaping @Sendable () -> Void) {
        lock.lock()
        handler = onChange
        lock.unlock()
    }

    func startObservingWake(_ onWake: @escaping @Sendable () -> Void) {
        lock.lock()
        wakeHandler = onWake
        lock.unlock()
    }

    /// Reports a wake from sleep the way the system notification would.
    func simulateWake() {
        lock.lock()
        let wakeHandler = self.wakeHandler
        lock.unlock()
        wakeHandler?()
    }

    func stopObserving() {
        lock.lock()
        handler = nil
        wakeHandler = nil
        lock.unlock()
    }
}

/// Collects what the indexer publishes on main.
final class AgentHistoryPublishedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStatuses: [AgentHistoryStatus] = []
    private var recordedSnapshots: [AgentHistoryMetadataSnapshot] = []
    private var statusWaiters: [(predicate: (AgentHistoryStatus) -> Bool, expectation: XCTestExpectation)] = []
    private var snapshotWaiters: [(predicate: (AgentHistoryMetadataSnapshot) -> Bool, expectation: XCTestExpectation)] = []

    var statuses: [AgentHistoryStatus] { lock.lock(); defer { lock.unlock() }; return recordedStatuses }
    var snapshots: [AgentHistoryMetadataSnapshot] { lock.lock(); defer { lock.unlock() }; return recordedSnapshots }

    func expectStatus(_ testCase: XCTestCase, _ description: String, where predicate: @escaping (AgentHistoryStatus) -> Bool) -> XCTestExpectation {
        let expectation = testCase.expectation(description: description)
        lock.lock()
        statusWaiters.append((predicate, expectation))
        lock.unlock()
        return expectation
    }

    func expectSnapshot(_ testCase: XCTestCase, _ description: String, where predicate: @escaping (AgentHistoryMetadataSnapshot) -> Bool) -> XCTestExpectation {
        let expectation = testCase.expectation(description: description)
        lock.lock()
        snapshotWaiters.append((predicate, expectation))
        lock.unlock()
        return expectation
    }

    func record(_ status: AgentHistoryStatus) {
        lock.lock()
        recordedStatuses.append(status)
        let matched = statusWaiters.filter { $0.predicate(status) }
        statusWaiters.removeAll { waiter in matched.contains { $0.expectation === waiter.expectation } }
        lock.unlock()
        matched.forEach { $0.expectation.fulfill() }
    }

    func record(_ snapshot: AgentHistoryMetadataSnapshot) {
        lock.lock()
        recordedSnapshots.append(snapshot)
        let matched = snapshotWaiters.filter { $0.predicate(snapshot) }
        snapshotWaiters.removeAll { waiter in matched.contains { $0.expectation === waiter.expectation } }
        lock.unlock()
        matched.forEach { $0.expectation.fulfill() }
    }
}

/// A settable clock for indexer tests (grace periods, root-missing intervals).
final class AgentHistoryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = AgentHistoryTestIndex.fixedNow) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

/// A temp index, a state store and indexers over one fake source; every indexer is stopped in
/// teardown before the index directory is removed. The default source's root is an existing
/// temp folder (`rootURL`), so reconciles see a present root.
final class AgentHistoryIndexerHarness {
    let index: AgentHistoryTestIndex
    let stateStore: AgentHistoryStateStore
    let rootURL: URL
    let source: FakeHistorySource
    let clock = AgentHistoryTestClock()
    let recorder = AgentHistoryPublishedRecorder()
    private unowned let testCase: XCTestCase

    init(testCase: XCTestCase, source: FakeHistorySource? = nil) {
        self.testCase = testCase
        self.index = AgentHistoryTestIndex(testCase: testCase)
        self.stateStore = AgentHistoryStateStore(fileURL: index.paths.stateURL)
        let rootURL = index.directoryURL.appendingPathComponent("fake-root", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        self.rootURL = rootURL
        self.source = source ?? FakeHistorySource(rootPath: rootURL.path)
    }

    func makeIndexer(
        messageLimit: Int = 500,
        excludedFolders: [String] = [],
        conditions: any AgentHistorySystemConditions = FakeSystemConditions(),
        source overrideSource: FakeHistorySource? = nil,
        extraSources: [FakeHistorySource] = [],
        fileEventLatency: TimeInterval = 2.0
    ) -> AgentHistoryIndexer {
        var limits = AgentHistoryIngestLimits()
        limits.messages = messageLimit
        let sources = [overrideSource ?? self.source] + extraSources
        let recorder = self.recorder
        let clock = self.clock
        var configuration = AgentHistoryIndexerConfiguration(
            enabledAgents: Set(AgentHistoryAgent.allCases), excludedFolders: excludedFolders, limits: limits
        )
        configuration.fileEventLatency = fileEventLatency
        let indexer = AgentHistoryIndexer(
            storage: index.storage,
            stateStore: stateStore,
            makeSources: { sources },
            configuration: configuration,
            systemConditions: conditions,
            now: { clock.now },
            onStatusChange: { recorder.record($0) },
            onSnapshotChange: { recorder.record($0) }
        )
        testCase.addTeardownBlock {
            indexer.stop(timeout: 2)
        }
        return indexer
    }

    /// A second existing root folder (for a second fake source).
    func makeRoot(_ name: String) -> URL {
        let url = index.directoryURL.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func read<T>(_ body: (AgentHistoryDatabase) throws -> T) throws -> T {
        try index.storage.readers.withReader(body)
    }

    func count(_ sql: String, _ bindings: [AgentHistoryValue] = []) throws -> Int {
        try read { try AgentHistoryFixtures.count($0, sql, bindings) }
    }

    /// Records usage the way the launcher would, on a second connection while the indexer idles.
    func setOpens(_ opens: Int, nativeID: String) throws {
        let db = try AgentHistoryDatabase(url: index.paths.databaseURL, mode: .readWrite, busyTimeoutMilliseconds: 2_000)
        defer { db.close() }
        try db.run("UPDATE sessions SET opens = ?, last_opened_at = ? WHERE native_id = ?",
                   [.of(opens), .integer(1_793_000_000_000), .text(nativeID)])
    }

    func sessionRowID(_ nativeID: String) throws -> Int64? {
        try read { try $0.scalarInt64("SELECT id FROM sessions WHERE native_id = ?", [.text(nativeID)]) }
    }

    func messageTexts() throws -> [String] {
        try read { try $0.query("SELECT text FROM messages ORDER BY session_id, seq") { $0.string(0) } }
    }
}
