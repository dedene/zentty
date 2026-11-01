import Foundation
import XCTest
@testable import Zentty

/// A real (temp-directory) Agent History index with sessions, messages and artifacts inserted
/// through `AgentHistoryStore`, plus a metadata index and a search engine over it. The clock is
/// fixed at `now`; times are given in days before it.
final class HistorySearchFixture: @unchecked Sendable {
    static let dayMs: Int64 = 86_400_000
    /// 2026-11-01 12:00:00 UTC.
    static let nowMs: Int64 = 1_793_534_400_000

    let index: AgentHistoryTestIndex
    let exclusions = Box(AgentHistoryExclusionMatcher(folders: []))
    /// The persisted agent selection the engine gates on; every agent unless a test turns one off.
    let enabledAgents = Box(Set(AgentHistoryAgent.allCases))
    var now: Date { Date(timeIntervalSince1970: TimeInterval(Self.nowMs) / 1000) }
    private var sourceIDs: [AgentHistoryAgent: Int64] = [:]
    private var sessionSources: [Int64: Int64] = [:]
    private var nextSeq: [Int64: Int] = [:]
    private var generation: UInt64 = 0

    /// Thread-safe holder for values the engine reads through `@Sendable` providers.
    final class Box<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value

        init(_ value: Value) { stored = value }

        var value: Value {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func set(_ value: Value) {
            lock.lock()
            stored = value
            lock.unlock()
        }
    }

    init(testCase: XCTestCase, tokenizer: AgentHistoryTokenizer = .trigram, readerCount: Int = 3) throws {
        var options = AgentHistoryStorage.Options()
        options.tokenizerOverride = tokenizer
        options.readerCount = readerCount
        index = AgentHistoryTestIndex(testCase: testCase, options: options)
        try index.openWriter()
    }

    var writer: AgentHistoryDatabase {
        get throws { try index.openWriter() }
    }

    func store() throws -> AgentHistoryStore { try index.makeStore() }

    static func ms(daysAgo: Double) -> Int64 {
        nowMs - Int64(daysAgo * Double(dayMs))
    }

    // MARK: - Inserts

    @discardableResult
    func addSource(_ agent: AgentHistoryAgent, enabled: Bool = true) throws -> Int64 {
        let id = try index.makeSource(agent, root: "/fixtures/\(agent.rawValue)")
        sourceIDs[agent] = id
        try store().setSourceEnabled(id: id, enabled)
        return id
    }

    /// Inserts a session (its source on first use). Visibility needs at least one user message.
    @discardableResult
    func addSession(
        _ nativeID: String,
        agent: AgentHistoryAgent = .claude,
        title: String = "",
        cwd: String? = nil,
        repo: String? = nil,
        mainRepo: String? = nil,
        branch: String? = nil,
        updatedDaysAgo: Double = 1,
        archived: Bool = false,
        opens: Int = 0,
        lastOpenedDaysAgo: Double? = nil,
        parent: String? = nil
    ) throws -> Int64 {
        let sourceID = try sourceIDs[agent] ?? addSource(agent)
        var draft = AgentHistorySessionDraft(nativeID: nativeID)
        draft.title = title
        draft.titleKind = .custom
        draft.cwd = cwd
        draft.repoRoot = repo
        draft.mainRepoRoot = mainRepo
        draft.branch = branch
        draft.createdAtMs = Self.ms(daysAgo: updatedDaysAgo + 1)
        draft.updatedAtMs = Self.ms(daysAgo: updatedDaysAgo)
        draft.archived = archived
        draft.parentNativeID = parent
        let id = try store().upsertSession(sourceID: sourceID, unitKey: nativeID, draft)
        if opens > 0 {
            try writer.run(
                "UPDATE sessions SET opens = ?, last_opened_at = ? WHERE id = ?",
                [.of(opens), .of(lastOpenedDaysAgo.map { Self.ms(daysAgo: $0) }), .integer(id)])
        }
        sessionSources[id] = sourceID
        return id
    }

    /// Appends a message with the next `seq` and refreshes the turn count. Returns its row id.
    @discardableResult
    func addMessage(session: Int64, role: AgentHistoryRole = .user, atMs: Int64, text: String) throws -> Int64 {
        let seq = nextSeq[session, default: 0]
        nextSeq[session] = seq + 1
        let store = try store()
        let draft = AgentHistoryMessageDraft(
            sessionNativeID: "", seq: seq, role: role, atMs: atMs,
            text: text, searchText: AgentHistorySearchText.normalize(text))
        try store.upsertMessages(sessionID: session, [draft])
        try store.refreshTurnCount(sessionID: session)
        return try XCTUnwrap(try writer.scalarInt64(
            "SELECT id FROM messages WHERE session_id = ? AND seq = ?", [.integer(session), .of(seq)]))
    }

    @discardableResult
    func addMessage(session: Int64, role: AgentHistoryRole = .user, daysAgo: Double, text: String) throws -> Int64 {
        try addMessage(session: session, role: role, atMs: Self.ms(daysAgo: daysAgo), text: text)
    }

    /// Many messages in one transaction (`texts[i]` at `startMs + i * stepMs`).
    func addMessages(session: Int64, role: AgentHistoryRole = .user, startMs: Int64, stepMs: Int64 = 1, texts: [String]) throws {
        let store = try store()
        try writer.transaction {
            var drafts: [AgentHistoryMessageDraft] = []
            for (offset, text) in texts.enumerated() {
                let seq = nextSeq[session, default: 0]
                nextSeq[session] = seq + 1
                drafts.append(AgentHistoryMessageDraft(
                    sessionNativeID: "", seq: seq, role: role, atMs: startMs + Int64(offset) * stepMs,
                    text: text, searchText: AgentHistorySearchText.normalize(text)))
            }
            try store.upsertMessages(sessionID: session, drafts)
            try store.refreshTurnCount(sessionID: session)
        }
    }

    func addArtifact(session: Int64, kind: AgentHistoryArtifactKind, value: String, daysAgo: Double) throws {
        let draft = AgentHistoryArtifactDraft(
            sessionNativeID: "", seq: max(nextSeq[session, default: 0] - 1, 0), kind: kind, value: value,
            searchText: AgentHistorySearchText.normalize(value), atMs: Self.ms(daysAgo: daysAgo))
        try store().upsertArtifacts(sessionID: session, [draft])
    }

    // MARK: - Engine

    func snapshot() throws -> AgentHistoryMetadataSnapshot {
        generation += 1
        return AgentHistoryMetadataSnapshot(
            generation: generation, sessions: try store().allVisibleSessionSummaries(), isComplete: true)
    }

    func metadataIndex() throws -> HistoryMetadataIndex {
        let snapshot = try snapshot()
        let exclusions = self.exclusions
        return HistoryMetadataIndex(snapshot: { snapshot }, exclusions: { exclusions.value })
    }

    /// An engine over the current rows (the metadata snapshot is taken now).
    func engine(
        metadataIndex: HistoryMetadataIndex? = nil,
        tuning: HistorySearchEngine.Tuning = HistorySearchEngine.Tuning()
    ) throws -> HistorySearchEngine {
        let storage = index.storage
        let exclusions = self.exclusions
        let enabledAgents = self.enabledAgents
        return HistorySearchEngine(
            readers: storage.readers,
            metadataIndex: try metadataIndex ?? self.metadataIndex(),
            tokenizer: { storage.tokenizer ?? .none },
            exclusions: { exclusions.value },
            enabledAgents: { enabledAgents.value },
            tuning: tuning
        )
    }

    func context(_ scope: AgentHistoryScope = .all, currentRepositoryKey: String? = nil) -> HistorySearchContext {
        HistorySearchContext(scope: scope, currentRepositoryKey: currentRepositoryKey, now: now)
    }

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func query(_ raw: String) -> HistoryQuery {
        HistoryQueryParser.parse(raw, calendar: utc)
    }

    static func projectScope(_ key: String, allowsCWDPrefix: Bool = true) -> AgentHistoryScope {
        .project(AgentHistoryProjectScope(
            key: key, displayName: (key as NSString).lastPathComponent, allowsCWDPrefix: allowsCWDPrefix))
    }
}
