import Foundation

/// One indexed session as the palette, the snapshot and the CLI see it. Search keys are
/// derived once at init (off-main) with `AgentHistorySearchText.normalize`.
struct AgentHistorySessionSummary: Hashable, Sendable {
    let id: Int64
    let sourceID: Int64
    let sourceRoot: String
    let agent: AgentHistoryAgent
    let nativeID: String
    let title: String
    let titleKind: AgentHistoryTitleKind
    let cwd: String?
    let repoRoot: String?
    let mainRepoRoot: String?
    let branch: String?
    let model: String?
    let effort: String?
    let generation: String?
    let transcriptPath: String?
    let createdAtMs: Int64
    let updatedAtMs: Int64
    let lastUserAtMs: Int64?
    let turnCount: Int
    let isArchived: Bool
    let opens: Int
    let lastOpenedAtMs: Int64?

    /// Last component of `mainRepoRoot ?? repoRoot`.
    let repoName: String?
    /// Last component of `cwd`.
    let folderName: String?
    let titleKey: String
    let branchKey: String?
    let repoKey: String?
    let folderKey: String?

    var key: AgentHistorySessionKey { AgentHistorySessionKey(agent: agent, nativeID: nativeID) }
    var createdAt: Date { Self.date(ms: createdAtMs) }
    var updatedAt: Date { Self.date(ms: updatedAtMs) }
    var lastOpenedAt: Date? { lastOpenedAtMs.map(Self.date(ms:)) }

    /// Column order read by `init(row:)`. Callers append `WHERE …` / `ORDER BY …`. The join
    /// only admits agents this build knows, so `init(row:)` never sees an unknown agent.
    static let selectSQL = """
        SELECT s.id, s.source_id, src.root, src.agent, s.native_id, s.title, s.title_kind,
               s.cwd, s.repo_root, s.main_repo_root, s.branch, s.model, s.effort, s.generation,
               s.transcript_path, s.created_at, s.updated_at, s.last_user_at, s.turn_count,
               s.archived, s.opens, s.last_opened_at
        FROM sessions s
        JOIN sources src ON src.id = s.source_id
          AND src.agent IN (\(AgentHistoryAgent.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")))
        """

    init(row: AgentHistoryRow) {
        let agentRaw = row.string(3)
        let kindRaw = row.string(6)
        self.init(
            id: row.int64(0),
            sourceID: row.int64(1),
            sourceRoot: row.string(2),
            // `selectSQL` filters unknown agents in its join; the fallback is unreachable.
            agent: AgentHistoryAgent(rawValue: agentRaw) ?? .claude,
            nativeID: row.string(4),
            title: row.string(5),
            titleKind: AgentHistoryTitleKind(rawValue: kindRaw) ?? .firstPrompt,
            cwd: row.optionalString(7),
            repoRoot: row.optionalString(8),
            mainRepoRoot: row.optionalString(9),
            branch: row.optionalString(10),
            model: row.optionalString(11),
            effort: row.optionalString(12),
            generation: row.optionalString(13),
            transcriptPath: row.optionalString(14),
            createdAtMs: row.int64(15),
            updatedAtMs: row.int64(16),
            lastUserAtMs: row.optionalInt64(17),
            turnCount: Int(row.int64(18)),
            isArchived: row.bool(19),
            opens: Int(row.int64(20)),
            lastOpenedAtMs: row.optionalInt64(21)
        )
    }

    init(
        id: Int64, sourceID: Int64, sourceRoot: String, agent: AgentHistoryAgent, nativeID: String,
        title: String, titleKind: AgentHistoryTitleKind,
        cwd: String? = nil, repoRoot: String? = nil, mainRepoRoot: String? = nil, branch: String? = nil,
        model: String? = nil, effort: String? = nil, generation: String? = nil, transcriptPath: String? = nil,
        createdAtMs: Int64, updatedAtMs: Int64, lastUserAtMs: Int64? = nil,
        turnCount: Int, isArchived: Bool = false, opens: Int = 0, lastOpenedAtMs: Int64? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceRoot = sourceRoot
        self.agent = agent
        self.nativeID = nativeID
        self.title = title
        self.titleKind = titleKind
        self.cwd = cwd
        self.repoRoot = repoRoot
        self.mainRepoRoot = mainRepoRoot
        self.branch = branch
        self.model = model
        self.effort = effort
        self.generation = generation
        self.transcriptPath = transcriptPath
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.lastUserAtMs = lastUserAtMs
        self.turnCount = turnCount
        self.isArchived = isArchived
        self.opens = opens
        self.lastOpenedAtMs = lastOpenedAtMs

        let repoName = Self.lastComponent(mainRepoRoot ?? repoRoot)
        let folderName = Self.lastComponent(cwd)
        self.repoName = repoName
        self.folderName = folderName
        self.titleKey = AgentHistorySearchText.normalize(title)
        self.branchKey = branch.map(AgentHistorySearchText.normalize)
        self.repoKey = repoName.map(AgentHistorySearchText.normalize)
        self.folderKey = folderName.map(AgentHistorySearchText.normalize)
    }

    private static func lastComponent(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let component = (path as NSString).lastPathComponent
        return component.isEmpty || component == "/" ? nil : component
    }

    private static func date(ms: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}
