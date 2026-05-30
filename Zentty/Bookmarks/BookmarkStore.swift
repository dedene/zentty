import Foundation
import OSLog

private let bookmarkStoreLogger = Logger(subsystem: "be.zenjoy.zentty", category: "Bookmarks")

@MainActor
final class BookmarkStore {
    private(set) var templates: [WorkspaceTemplate]

    /// Invoked when persisting changes to disk fails. RootViewController wires
    /// this to surface a one-shot NSAlert so the user notices that their
    /// bookmark didn't actually save (in-memory state would otherwise diverge
    /// from disk silently).
    var onPersistError: ((Error) -> Void)?

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var observers: [UUID: () -> Void] = [:]

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        self.templates = Self.load(from: fileURL, fileManager: fileManager, decoder: decoder)
    }

    @discardableResult
    func addObserver(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    func template(withID id: UUID) -> WorkspaceTemplate? {
        templates.first { $0.id == id }
    }

    func upsert(_ template: WorkspaceTemplate) {
        var updated = template
        updated.updatedAt = Date()
        if let index = templates.firstIndex(where: { $0.id == updated.id }) {
            templates[index] = updated
        } else {
            templates.append(updated)
        }
        persistAndNotify()
    }

    func delete(id: UUID) {
        guard templates.contains(where: { $0.id == id }) else {
            return
        }
        templates.removeAll { $0.id == id }
        persistAndNotify()
    }

    func rename(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = templates.firstIndex(where: { $0.id == id }) else {
            return
        }
        templates[index].name = trimmed
        templates[index].updatedAt = Date()
        persistAndNotify()
    }

    func setPinned(id: UUID, pinned: Bool) {
        guard let index = templates.firstIndex(where: { $0.id == id }),
              templates[index].pinned != pinned else {
            return
        }
        templates[index].pinned = pinned
        templates[index].updatedAt = Date()
        persistAndNotify()
    }

    func recordUse(id: UUID) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else {
            return
        }
        templates[index].lastUsedAt = Date()
        persistAndNotify()
    }

    func duplicate(id: UUID) -> WorkspaceTemplate? {
        guard let original = template(withID: id) else {
            return nil
        }
        var copy = original
        copy.id = UUID()
        copy.name = duplicateName(for: original.name)
        copy.pinned = false
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.lastUsedAt = nil
        templates.append(copy)
        persistAndNotify()
        return copy
    }

    private func duplicateName(for source: String) -> String {
        let base = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = base.isEmpty ? "Copy" : "\(base) copy"
        var attempt = candidate
        var suffix = 2
        while templates.contains(where: { $0.name == attempt }) {
            attempt = "\(candidate) \(suffix)"
            suffix += 1
        }
        return attempt
    }

    private func persistAndNotify() {
        persist()
        for handler in observers.values {
            handler()
        }
    }

    private func persist() {
        let bundle = WorkspaceTemplateBundle(savedAt: Date(), templates: templates)
        do {
            // Write through a symlinked bookmarks.json so dotfile setups keep their link
            // instead of having it clobbered by the atomic temp+rename.
            let targetURL = fileManager.resolvingSymlinkTarget(at: fileURL)
            try fileManager.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(bundle)
            try data.write(to: targetURL, options: .atomic)
        } catch {
            bookmarkStoreLogger.error(
                "Failed to persist bookmarks to \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            onPersistError?(error)
        }
    }

    private static func load(
        from url: URL,
        fileManager: FileManager,
        decoder: JSONDecoder
    ) -> [WorkspaceTemplate] {
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let bundle = try decoder.decode(WorkspaceTemplateBundle.self, from: data)
            if bundle.schemaVersion > WorkspaceTemplateBundle.currentSchemaVersion {
                bookmarkStoreLogger.warning(
                    "Bookmarks file at \(url.path, privacy: .public) has schemaVersion \(bundle.schemaVersion), newer than current \(WorkspaceTemplateBundle.currentSchemaVersion). Loading anyway; saves may drop unknown fields."
                )
            }
            return bundle.templates
        } catch {
            preserveCorruptFile(at: url, fileManager: fileManager, error: error)
            return []
        }
    }

    private static func preserveCorruptFile(
        at url: URL,
        fileManager: FileManager,
        error: Error
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(timestamp).json")
        do {
            try fileManager.moveItem(at: url, to: backupURL)
            bookmarkStoreLogger.error(
                "Failed to read bookmarks at \(url.path, privacy: .public); moved corrupt file aside to \(backupURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        } catch let moveError {
            bookmarkStoreLogger.error(
                "Failed to read bookmarks at \(url.path, privacy: .public) and could not preserve corrupt file (\(moveError.localizedDescription, privacy: .public)). Original error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
