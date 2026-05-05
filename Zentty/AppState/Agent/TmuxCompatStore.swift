import Foundation
import OSLog

private let storeLogger = Logger(subsystem: "be.zenjoy.zentty", category: "tmux-compat-store")

/// Per-worklane anchor recorded when Claude Code's leader pane spawns its
/// first subagent column. Subsequent `tmux split-window` calls land in this
/// column instead of scattering across the layout.
struct WorklaneAnchor: Codable, Equatable {
    var leaderPaneID: String
    /// Top-to-bottom subagent pane IDs inside the right column.
    var columnPaneIDs: [String]
    /// Leader column width snapshot taken just before the team's first
    /// subagent split. Restored when the last subagent is killed so the
    /// pre-team layout returns even when other columns existed alongside
    /// the leader. Nil for legacy anchors written before this snapshot was
    /// recorded.
    var preTeamLeaderColumnWidth: CGFloat? = nil
}

/// File-backed JSON store for tmux compatibility state. State is
/// keyed by `WorklaneID.rawValue` so simultaneous teams in different
/// worklanes never collide.
///
/// `version` is written into every saved file so future format changes can
/// be migrated without losing user state. Older readers tolerate unknown
/// keys (Codable's default decoder treats missing keys as the property's
/// default), so adding fields in v2 is safe; bump `version` whenever the
/// shape changes incompatibly.
struct TmuxCompatStore: Codable, Equatable {
    var version: Int = 1
    var buffers: [String: String] = [:]
    var anchors: [String: WorklaneAnchor] = [:]
    var activePaneIDs: [String: String] = [:]

    static let empty = TmuxCompatStore()

    init(
        version: Int = 1,
        buffers: [String: String] = [:],
        anchors: [String: WorklaneAnchor] = [:],
        activePaneIDs: [String: String] = [:]
    ) {
        self.version = version
        self.buffers = buffers
        self.anchors = anchors
        self.activePaneIDs = activePaneIDs
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        buffers = try container.decodeIfPresent([String: String].self, forKey: .buffers) ?? [:]
        anchors = try container.decodeIfPresent([String: WorklaneAnchor].self, forKey: .anchors) ?? [:]
        activePaneIDs = try container.decodeIfPresent([String: String].self, forKey: .activePaneIDs) ?? [:]
    }
}

enum TmuxCompatStoreIO {
    private static let lock = NSLock()

    static func defaultFileURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("zentty", isDirectory: true)
            .appendingPathComponent("tmux-compat-store.json", isDirectory: false)
    }

    static func load(from fileURL: URL = defaultFileURL()) -> TmuxCompatStore {
        guard let data = try? Data(contentsOf: fileURL) else {
            return .empty
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(TmuxCompatStore.self, from: data)
        } catch {
            storeLogger.warning(
                "Failed to decode tmux-compat-store.json: \(error.localizedDescription, privacy: .public). Falling back to empty store."
            )
            return .empty
        }
    }

    /// Write atomically: serialize to a temp file in the same directory, then
    /// rename. Avoids a partially-written file if the process dies mid-write.
    static func save(_ store: TmuxCompatStore, to fileURL: URL = defaultFileURL()) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(store)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// Atomic load-modify-save. Logs at warning level if the save fails so
    /// `try?` callers don't lose state silently.
    static func mutate(
        at fileURL: URL = defaultFileURL(),
        _ body: (inout TmuxCompatStore) -> Void
    ) {
        lock.lock()
        defer {
            lock.unlock()
        }
        var current = load(from: fileURL)
        body(&current)
        do {
            try save(current, to: fileURL)
        } catch {
            storeLogger.warning(
                "Failed to save tmux-compat-store.json: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
