import Foundation
import OSLog

private let appConfigLogger = Logger(subsystem: "be.zenjoy.zentty", category: "Config")

final class AppConfigStore: @unchecked Sendable {
    typealias ChangeHandler = @Sendable (AppConfig) -> Void

    private enum LoadResult {
        case missing
        case loaded(AppConfig)
        case invalid
    }

    private final class FileWatcher {
        var onChange: (@Sendable () -> Void)?

        private let queue = DispatchQueue(label: "com.zentty.app-config-watcher")
        private var source: DispatchSourceFileSystemObject?
        private var descriptor: Int32 = -1
        private var debounceWorkItem: DispatchWorkItem?

        func watch(directoryURL: URL) {
            stop()

            let descriptor = open(directoryURL.path, O_EVTONLY)
            guard descriptor >= 0 else {
                return
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .extend, .attrib],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.scheduleChangeNotification()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()

            self.source = source
            self.descriptor = descriptor
        }

        func stop() {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            source?.cancel()
            source = nil
            descriptor = -1
        }

        deinit {
            stop()
        }

        private func scheduleChangeNotification() {
            debounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let onChange = self?.onChange else {
                    return
                }

                onChange()
            }
            debounceWorkItem = workItem
            queue.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        }
    }

    let fileURL: URL

    private(set) var current: AppConfig
    var onChange: ChangeHandler? {
        didSet {
            if let legacyObserverID {
                changeHandlers.removeValue(forKey: legacyObserverID)
                self.legacyObserverID = nil
            }

            guard let onChange else {
                return
            }

            let observerID = UUID()
            changeHandlers[observerID] = onChange
            legacyObserverID = observerID
        }
    }

    private let fileWatcher = FileWatcher()
    private var changeHandlers: [UUID: ChangeHandler] = [:]
    private var legacyObserverID: UUID?

    init(
        fileURL: URL? = nil,
        sidebarWidthDefaults: UserDefaults = .standard,
        sidebarVisibilityDefaults: UserDefaults = .standard,
        paneLayoutDefaults: UserDefaults = .standard
    ) {
        let resolvedFileURL = fileURL ?? Self.defaultFileURL()
        self.fileURL = resolvedFileURL

        let fileManager = FileManager.default
        let migrated = AppConfig.migrated(
            sidebarWidthDefaults: sidebarWidthDefaults,
            sidebarVisibilityDefaults: sidebarVisibilityDefaults,
            paneLayoutDefaults: paneLayoutDefaults
        )

        switch Self.load(fileURL: resolvedFileURL) {
        case .loaded(let persisted):
            current = persisted.normalized()
        case .missing:
            current = migrated.normalized()
            try? Self.persist(config: current, to: resolvedFileURL, fileManager: fileManager)
        case .invalid:
            current = AppConfig.default.normalized()
            appConfigLogger.error("Ignoring invalid config file at \(resolvedFileURL.path, privacy: .public)")
        }

        fileWatcher.onChange = { [weak self] in
            DispatchQueue.main.async {
                self?.reloadFromDiskIfNeeded()
            }
        }
        let watchDirectoryURL = resolvedFileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: watchDirectoryURL, withIntermediateDirectories: true)
        fileWatcher.watch(directoryURL: watchDirectoryURL)
    }

    static func defaultFileURL(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectoryURL
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("zentty", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    static func temporaryFileURL(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix).\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    func update(_ mutate: (inout AppConfig) throws -> Void) throws {
        var updated = current
        try mutate(&updated)
        updated = updated.normalized()
        try Self.persist(config: updated, to: fileURL, fileManager: .default)
        current = updated
        notifyChange()
    }

    @discardableResult
    func addObserver(_ handler: @escaping ChangeHandler) -> UUID {
        let observerID = UUID()
        changeHandlers[observerID] = handler
        return observerID
    }

    func removeObserver(_ observerID: UUID) {
        changeHandlers.removeValue(forKey: observerID)
        if legacyObserverID == observerID {
            legacyObserverID = nil
            onChange = nil
        }
    }

    func reloadFromDisk() {
        reloadFromDiskIfNeeded()
    }

    private func reloadFromDiskIfNeeded() {
        switch Self.load(fileURL: fileURL) {
        case .loaded(let reloaded):
            guard reloaded != current else {
                return
            }

            current = reloaded
            notifyChange()
        case .invalid:
            appConfigLogger.error("Ignoring invalid config reload at \(self.fileURL.path, privacy: .public)")
        case .missing:
            return
        }
    }

    private func notifyChange() {
        for handler in changeHandlers.values {
            handler(current)
        }
    }

    private static func load(fileURL: URL) -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .missing
        }

        guard
            let data = try? Data(contentsOf: fileURL),
            let source = String(data: data, encoding: .utf8),
            let config = AppConfigTOML.decode(source)
        else {
            return .invalid
        }

        return .loaded(config.normalized())
    }

    private static func persist(config: AppConfig, to fileURL: URL, fileManager: FileManager) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let source = AppConfigTOML.encode(config.normalized())
        try Data(source.utf8).write(to: fileURL, options: .atomic)
    }
}
