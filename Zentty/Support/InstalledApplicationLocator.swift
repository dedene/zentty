import AppKit

/// Finds installed apps (editors, browsers) and remembers the answers.
///
/// Chrome refreshes and menu validation ask "is Cursor installed? where is
/// Firefox?" on every focus change. Answering from LaunchServices and a listing
/// of `/Applications` each time kept the main thread busy, so results stay
/// cached until the app folders change or Zentty becomes active again (an app
/// installed elsewhere usually means the user was in another app).
///
/// `generation` increases on every invalidation, so callers that derive larger
/// structures from these answers can memoize on it.
@MainActor
final class InstalledApplicationLocator {
    struct Environment {
        var searchDirectories: [URL]
        var urlForBundleIdentifier: (String) -> URL?
        var fileExists: (String) -> Bool
        var isReadableFile: (String) -> Bool
        var contentsOfDirectory: (URL) -> [URL]?

        static func live(
            workspace: NSWorkspace = .shared,
            fileManager: FileManager = .default
        ) -> Environment {
            Environment(
                searchDirectories: [
                    URL(fileURLWithPath: "/Applications", isDirectory: true),
                    fileManager.homeDirectoryForCurrentUser
                        .appendingPathComponent("Applications", isDirectory: true),
                ],
                urlForBundleIdentifier: { workspace.urlForApplication(withBundleIdentifier: $0) },
                fileExists: { fileManager.fileExists(atPath: $0) },
                isReadableFile: { fileManager.isReadableFile(atPath: $0) },
                contentsOfDirectory: {
                    try? fileManager.contentsOfDirectory(
                        at: $0,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )
                }
            )
        }
    }

    private struct Query: Hashable {
        let bundleIdentifiers: [String]
        let exactNames: [String]
        let prefixNames: [String]
    }

    static let shared = InstalledApplicationLocator(environment: .live(), observesChanges: true)

    private(set) var generation = 0

    private let environment: Environment
    private var applicationURLs: [Query: URL?] = [:]
    private var fileExistence: [String: Bool] = [:]
    private var fileReadability: [String: Bool] = [:]
    private var directoryListings: [URL: [URL]?] = [:]
    private var directoryWatcher: DirectoryChangeWatcher?
    // Only the process-wide `shared` locator observes changes, and it is never
    // released, so the observer token needs no removal.
    private var activationObserver: NSObjectProtocol?

    init(environment: Environment, observesChanges: Bool = false) {
        self.environment = environment
        if observesChanges {
            startObservingChanges()
        }
    }

    /// Looks the app up by bundle identifier first, then by exact bundle name,
    /// then by name prefix (versioned JetBrains installs such as
    /// "IntelliJ IDEA 2026.1.app") in the search directories.
    func applicationURL(
        bundleIdentifiers: [String],
        exactNames: [String],
        prefixNames: [String] = []
    ) -> URL? {
        let query = Query(bundleIdentifiers: bundleIdentifiers, exactNames: exactNames, prefixNames: prefixNames)
        if let cached = applicationURLs[query] {
            return cached
        }

        let resolved = resolveApplicationURL(for: query)
        applicationURLs[query] = resolved
        return resolved
    }

    func fileExists(atPath path: String) -> Bool {
        if let cached = fileExistence[path] {
            return cached
        }
        let exists = environment.fileExists(path)
        fileExistence[path] = exists
        return exists
    }

    func isReadableFile(atPath path: String) -> Bool {
        if let cached = fileReadability[path] {
            return cached
        }
        let readable = environment.isReadableFile(path)
        fileReadability[path] = readable
        return readable
    }

    func invalidate() {
        applicationURLs.removeAll()
        fileExistence.removeAll()
        fileReadability.removeAll()
        directoryListings.removeAll()
        generation += 1
    }

    private func resolveApplicationURL(for query: Query) -> URL? {
        for bundleIdentifier in query.bundleIdentifiers {
            if let url = environment.urlForBundleIdentifier(bundleIdentifier) {
                return url
            }
        }

        for directoryURL in environment.searchDirectories {
            for exactName in query.exactNames {
                let candidateURL = directoryURL.appendingPathComponent(exactName, isDirectory: true)
                if fileExists(atPath: candidateURL.path) {
                    return candidateURL
                }
            }

            guard !query.prefixNames.isEmpty, let entries = listing(of: directoryURL) else {
                continue
            }

            if let prefixMatch = entries.first(where: { url in
                let name = url.lastPathComponent
                return name.hasSuffix(".app") && query.prefixNames.contains(where: { name.hasPrefix($0) })
            }) {
                return prefixMatch
            }
        }

        return nil
    }

    private func listing(of directoryURL: URL) -> [URL]? {
        if let cached = directoryListings[directoryURL] {
            return cached
        }
        let entries = environment.contentsOfDirectory(directoryURL)
        directoryListings[directoryURL] = entries
        return entries
    }

    private func startObservingChanges() {
        let watcher = DirectoryChangeWatcher(
            label: "be.zenjoy.zentty.installed-applications",
            debounceInterval: 1.0
        )
        watcher.onChange = { [weak self] in
            Task { @MainActor in
                self?.invalidate()
            }
        }
        watcher.watch(directoryURLs: environment.searchDirectories)
        directoryWatcher = watcher

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActorShim.assumeIsolated {
                self?.invalidate()
            }
        }
    }
}
