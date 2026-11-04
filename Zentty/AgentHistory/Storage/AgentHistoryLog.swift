import os

/// Loggers for Agent History. Public fields: counts, durations (ms), agent names,
/// SQLite result codes and state names. Never message text, titles, queries, paths
/// or native ids; `sqlite3_errmsg` only with `privacy: .private`.
enum AgentHistoryLog {
    static let indexer = Logger(subsystem: "be.zenjoy.zentty", category: "AgentHistory")
    static let search = Logger(subsystem: "be.zenjoy.zentty", category: "AgentHistorySearch")
}
