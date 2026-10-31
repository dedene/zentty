import CoreGraphics
import Foundation
import os

/// Persists ``FloatGeometryStore`` as JSON in user defaults.
enum FloatGeometryPreference {
    static let storageKey = "floatGeometries"

    private static let testDefaultsSuiteName = "ZenttyTests.FloatGeometryPreference"
    private static let logger = Logger(subsystem: "be.zenjoy.zentty", category: "FloatGeometryPreference")

    private struct PersistedEntry: Codable {
        let width: Double
        let height: Double
        let lastShownAt: Date
    }

    private struct PersistedPayload: Codable {
        var entries: [String: PersistedEntry]
    }

    static func restored(from defaults: UserDefaults) -> FloatGeometryStore {
        guard let data = defaults.data(forKey: storageKey) else {
            return FloatGeometryStore()
        }
        do {
            let payload = try JSONDecoder().decode(PersistedPayload.self, from: data)
            // Replay oldest-first so the LRU order (and any prune) survives the round trip.
            let sortedEntries = payload.entries.sorted { $0.value.lastShownAt < $1.value.lastShownAt }
            var store = FloatGeometryStore()
            for (key, value) in sortedEntries {
                store.remember(
                    FloatName(value: key),
                    size: CGSize(width: value.width, height: value.height),
                    now: value.lastShownAt
                )
            }
            return store
        } catch {
            logger.warning("Failed to decode float geometries: \(error.localizedDescription)")
            return FloatGeometryStore()
        }
    }

    static func persist(_ store: FloatGeometryStore, in defaults: UserDefaults) {
        let entries = Dictionary(uniqueKeysWithValues: store.entriesByName.map { name, entry in
            (name.value, PersistedEntry(
                width: Double(entry.size.width),
                height: Double(entry.size.height),
                lastShownAt: entry.lastShownAt
            ))
        })
        do {
            let data = try JSONEncoder().encode(PersistedPayload(entries: entries))
            defaults.set(data, forKey: storageKey)
        } catch {
            logger.warning("Failed to encode float geometries: \(error.localizedDescription)")
        }
    }

    /// Isolated defaults domain for tests; the app passes its own defaults to
    /// ``restored(from:)`` / ``persist(_:in:)``.
    static func userDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: testDefaultsSuiteName) else {
            return .standard
        }

        return defaults
    }

    static func reset() {
        UserDefaults(suiteName: testDefaultsSuiteName)?
            .removePersistentDomain(forName: testDefaultsSuiteName)
    }
}
