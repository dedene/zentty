import Foundation

final class SessionRestoreStore {
    struct LaunchDecision: Equatable, Sendable {
        enum Reason: String, Codable, Equatable, Sendable {
            case normalRestore
            case crashRecovery
        }

        var reason: Reason
        var envelope: SessionRestoreEnvelope
    }

    private struct LifecycleState: Codable, Equatable, Sendable {
        var cleanExit: Bool
        var updatedAt: Date
    }

    let snapshotURL: URL
    let lifecycleURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        snapshotURL: URL,
        lifecycleURL: URL,
        fileManager: FileManager = .default
    ) {
        self.snapshotURL = snapshotURL
        self.lifecycleURL = lifecycleURL
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    convenience init(configDirectoryURL: URL) {
        self.init(
            snapshotURL: configDirectoryURL.appendingPathComponent("restore-snapshot.json"),
            lifecycleURL: configDirectoryURL.appendingPathComponent("restore-lifecycle.json")
        )
    }

    func prepareForLaunch(restorePreferenceEnabled: Bool) throws -> LaunchDecision? {
        guard let envelope = try loadSnapshot() else {
            return nil
        }

        let previousLifecycle = try loadLifecycleState()
        if previousLifecycle?.cleanExit == false {
            return LaunchDecision(reason: .crashRecovery, envelope: envelope)
        }

        guard restorePreferenceEnabled else {
            return nil
        }

        return LaunchDecision(reason: .normalRestore, envelope: envelope)
    }

    func markLaunchStarted() throws {
        try persist(
            LifecycleState(cleanExit: false, updatedAt: Date()),
            to: lifecycleURL
        )
    }

    func markCleanExit() throws {
        try persist(
            LifecycleState(cleanExit: true, updatedAt: Date()),
            to: lifecycleURL
        )
    }

    func saveSnapshot(_ envelope: SessionRestoreEnvelope) throws {
        try persist(envelope, to: snapshotURL)
    }

    func consumeSnapshot() throws {
        try deleteSnapshot()
    }

    func deleteSnapshot() throws {
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return
        }

        try fileManager.removeItem(at: snapshotURL)
    }

    private func loadSnapshot() throws -> SessionRestoreEnvelope? {
        try load(SessionRestoreEnvelope.self, from: snapshotURL)
    }

    private func loadLifecycleState() throws -> LifecycleState? {
        try load(LifecycleState.self, from: lifecycleURL)
    }

    private func load<T: Decodable>(
        _ type: T.Type,
        from url: URL
    ) throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    private func persist<T: Encodable>(
        _ value: T,
        to url: URL
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}

struct SessionRestoreEnvelope: Codable, Equatable, Sendable {
    enum SaveReason: String, Codable, Equatable, Sendable {
        case liveSnapshot
        case cleanExit
    }

    var schemaVersion: Int
    var savedAt: Date
    var reason: SaveReason
    var workspace: WorkspaceRecipe

    init(
        schemaVersion: Int = 1,
        savedAt: Date = Date(),
        reason: SaveReason = .liveSnapshot,
        workspace: WorkspaceRecipe
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.reason = reason
        self.workspace = workspace
    }
}
