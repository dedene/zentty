import Foundation

/// Where the Agent History index lives on this Mac.
///
/// Pure value: resolving never touches the disk. `AgentHistoryStorage.ensureDirectory()` creates
/// the directory (0700, excluded from backups) when the index is first opened.
struct AgentHistoryPaths: Equatable, Sendable {
    static let directoryName = "AgentHistory"
    static let overrideEnvironmentKey = "ZENTTY_AGENT_HISTORY_DIR"

    static let databaseFileName = "index.sqlite"
    static let stateFileName = "state.json"
    static let corruptFilePrefix = "index.corrupt-"
    static let corruptFileSuffix = ".sqlite"

    let directoryURL: URL

    var databaseURL: URL { directoryURL.appendingPathComponent(Self.databaseFileName, isDirectory: false) }
    var walURL: URL { directoryURL.appendingPathComponent(Self.databaseFileName + "-wal", isDirectory: false) }
    var shmURL: URL { directoryURL.appendingPathComponent(Self.databaseFileName + "-shm", isDirectory: false) }
    var stateURL: URL { directoryURL.appendingPathComponent(Self.stateFileName, isDirectory: false) }

    /// `index.corrupt-20261031T101500Z.sqlite`: UTC, ISO 8601 basic format.
    func corruptDatabaseURL(at date: Date) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        return directoryURL.appendingPathComponent(
            Self.corruptFilePrefix + stamp + Self.corruptFileSuffix,
            isDirectory: false
        )
    }

    static func isCorruptCopyName(_ name: String) -> Bool {
        name.hasPrefix(corruptFilePrefix) && name.hasSuffix(corruptFileSuffix)
    }

    /// Resolve order:
    /// 1. `ZENTTY_AGENT_HISTORY_DIR` (tilde-expanded against `homeDirectoryURL`);
    /// 2. under XCTest: `<temp>/zentty-tests-<pid>/AgentHistory`, so a test that forgets to inject
    ///    paths never touches the real index;
    /// 3. a non-default config file (tests, tools): beside that file, the same rule as the
    ///    restore-state directory in `AppDelegate`;
    /// 4. the flavor's per-Mac state directory: `…/Application Support/Zentty[ Dev]/AgentHistory`.
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        flavor: ZenttyBuildFlavor = .current,
        configFileURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> AgentHistoryPaths {
        if let override = environment[overrideEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return AgentHistoryPaths(directoryURL: URL(
                fileURLWithPath: expandingTilde(override, homeDirectoryURL: homeDirectoryURL),
                isDirectory: true
            ).standardizedFileURL)
        }

        if environment["XCTestConfigurationFilePath"] != nil {
            return AgentHistoryPaths(directoryURL: fileManager.temporaryDirectory
                .appendingPathComponent("zentty-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true))
        }

        if let configFileURL,
           configFileURL.standardizedFileURL
            != AppConfigStore.defaultFileURL(homeDirectoryURL: homeDirectoryURL, flavor: flavor).standardizedFileURL {
            return AgentHistoryPaths(directoryURL: configFileURL.deletingLastPathComponent()
                .appendingPathComponent(directoryName, isDirectory: true))
        }

        return AgentHistoryPaths(directoryURL: flavor.stateDirectoryURL(homeDirectoryURL: homeDirectoryURL)
            .appendingPathComponent(directoryName, isDirectory: true))
    }

    private static func expandingTilde(_ path: String, homeDirectoryURL: URL) -> String {
        if path == "~" { return homeDirectoryURL.path }
        if path.hasPrefix("~/") { return homeDirectoryURL.path + String(path.dropFirst(1)) }
        return path
    }
}
