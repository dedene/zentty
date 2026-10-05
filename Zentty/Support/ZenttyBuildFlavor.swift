import Foundation

/// Which side-by-side install this binary is. `production` is the shipped
/// Zentty; `dev` is a locally built release candidate ("Zentty Dev") that runs
/// next to it and must not share any mutable app state with it.
///
/// Set at build time via the `ZENTTY_BUILD_FLAVOR` build setting, which lands
/// in Info.plist as `ZenttyBuildFlavor`. Missing or unknown values (Debug
/// builds, test runners) resolve to `production`, so every production name
/// below must stay exactly what it was before the flavor seam existed.
///
/// Deliberately *not* flavored: the runtime root `~/.config/zentty/run`
/// (shared with the CLI, already per-instance) and user agent manifests in
/// `~/.config/zentty/agents`.
enum ZenttyBuildFlavor: String, Equatable, Sendable {
    case production
    case dev

    static let infoDictionaryKey = "ZenttyBuildFlavor"

    static let current = ZenttyBuildFlavor(infoDictionary: Bundle.main.infoDictionary)

    /// User-facing app name ("Zentty" / "Zentty Dev") from CFBundleDisplayName.
    static let currentDisplayName = displayName(infoDictionary: Bundle.main.infoDictionary)

    init(infoDictionary: [String: Any]?) {
        let rawValue = infoDictionary?[Self.infoDictionaryKey] as? String
        self = rawValue.flatMap(Self.init(rawValue:)) ?? .production
    }

    /// Only trusts CFBundleDisplayName when the dictionary is a Zentty app
    /// bundle's (it carries the flavor key); test runners and tools fall back.
    static func displayName(infoDictionary: [String: Any]?) -> String {
        guard infoDictionary?[infoDictionaryKey] != nil,
              let name = infoDictionary?["CFBundleDisplayName"] as? String,
              !name.isEmpty else {
            return "Zentty"
        }
        return name
    }

    /// `~/.config/<name>`: config.toml, bookmarks.json, restore snapshots,
    /// tmux-compat state.
    var configDirectoryName: String {
        switch self {
        case .production: "zentty"
        case .dev: "zentty-dev"
        }
    }

    /// Folder under ~/Library/Application Support and ~/Library/Caches.
    var libraryFolderName: String {
        switch self {
        case .production: "Zentty"
        case .dev: "Zentty Dev"
        }
    }

    /// Prefix for libghostty override files written to the temp directory.
    var ghosttyTempFilePrefix: String {
        switch self {
        case .production: "zentty-ghostty-"
        case .dev: "zentty-dev-ghostty-"
        }
    }

    /// Manifest agent wrapper directory under the shared runtime root. Each
    /// app prunes ids it doesn't know and bakes its own bundle path into the
    /// scripts, so the two flavors can't share one.
    var agentWrappersDirectoryName: String {
        switch self {
        case .production: "agent-wrappers"
        case .dev: "agent-wrappers-dev"
        }
    }

    var selectionPasteboardName: String {
        switch self {
        case .production: "be.zenjoy.zentty.selection"
        case .dev: "be.zenjoy.zentty.dev.selection"
        }
    }

    func configDirectoryURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(configDirectoryName, isDirectory: true)
    }
}
