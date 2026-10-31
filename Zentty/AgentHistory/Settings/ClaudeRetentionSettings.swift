import Foundation

/// Claude Code's effective transcript retention (`cleanupPeriodDays`) for one config directory.
struct ClaudeRetentionStatus: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case defaultValue
        case userSettings
        case managedSettings
    }

    let configDirectory: URL
    let settingsFileURL: URL
    let effectiveDays: Int
    let source: Source
    let readError: ClaudeRetentionSettingsError?

    /// Offer "Keep 1 Year" only when the user's own file decides retention, it reads cleanly and
    /// the value is a real retention shorter than a year. `0` is never "raised": Claude Code
    /// treats it specially, so we leave it alone.
    var isNudgeEligible: Bool {
        readError == nil && source != .managedSettings && (1..<ClaudeRetentionSettings.recommendedDays).contains(effectiveDays)
    }
}

enum ClaudeRetentionWriteOutcome: Equatable, Sendable {
    case written(backupURL: URL?)
    case alreadySufficient(currentDays: Int)
}

enum ClaudeRetentionSettingsError: Error, Equatable, Sendable, LocalizedError {
    case invalidJSON(path: String)
    case notAnObject(path: String)
    case unexpectedValueType(path: String)
    case unreadable(path: String)
    case tooLarge(path: String)
    case directoryMissing(path: String)
    case verificationFailed(path: String)
    case changedDuringWrite(path: String)
    /// The backup or the settings file itself could not be written. Added in C2: the contract
    /// had no case for a failed write.
    case writeFailed(path: String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Claude's settings.json isn't valid JSON; nothing was changed."
        case .notAnObject:
            return "Claude's settings.json doesn't contain a JSON object; nothing was changed."
        case .unexpectedValueType:
            return "Claude's settings.json has a cleanupPeriodDays value that isn't a number; nothing was changed."
        case .unreadable:
            return "Zentty couldn't read Claude's settings.json; nothing was changed."
        case .tooLarge:
            return "Claude's settings.json is unexpectedly large; nothing was changed."
        case .directoryMissing:
            return "Claude Code's settings folder doesn't exist; nothing was changed."
        case .verificationFailed:
            return "Zentty couldn't update Claude's settings.json safely; nothing was changed."
        case .changedDuringWrite:
            return "Claude's settings.json changed while Zentty was updating it; nothing was changed. Try again."
        case .writeFailed:
            return "Zentty couldn't write Claude's settings.json."
        }
    }
}

/// Reads and, only on an explicit request, raises Claude Code's `cleanupPeriodDays`.
///
/// The writer never lowers a value, refuses anything it can't parse strictly, backs up the
/// original bytes first, keeps every other byte of the file where it can, writes through a
/// symlinked settings file, and keeps the file's POSIX permissions.
enum ClaudeRetentionSettings {
    static let key = "cleanupPeriodDays"
    static let defaultDays = 30
    static let recommendedDays = 365
    static let managedSettingsURL = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")
    static let settingsFileName = "settings.json"
    static let backupPrefix = "settings.json.zentty-backup-"
    static let maximumFileSize = 5 * 1024 * 1024

    static func defaultConfigDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let expanded: String
            if override == "~" {
                expanded = homeDirectoryURL.path
            } else if override.hasPrefix("~/") {
                expanded = homeDirectoryURL.appendingPathComponent(String(override.dropFirst(2))).path
            } else {
                expanded = override
            }
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return homeDirectoryURL.appendingPathComponent(".claude", isDirectory: true)
    }

    // MARK: - Status

    static func status(
        configDirectory: URL,
        managedSettingsURL: URL = managedSettingsURL,
        fileManager: FileManager = .default
    ) -> ClaudeRetentionStatus {
        let settingsURL = configDirectory.appendingPathComponent(settingsFileName)

        func make(_ days: Int, _ source: ClaudeRetentionStatus.Source, _ error: ClaudeRetentionSettingsError? = nil) -> ClaudeRetentionStatus {
            ClaudeRetentionStatus(
                configDirectory: configDirectory,
                settingsFileURL: settingsURL,
                effectiveDays: days,
                source: source,
                readError: error
            )
        }

        // Managed settings win over the user's file. An unreadable or malformed managed file
        // is treated as absent: it isn't ours to report on.
        if case let .success(object?) = readObject(at: managedSettingsURL, fileManager: fileManager),
           case let .success(days?) = retentionDays(in: object, path: managedSettingsURL.path) {
            return make(days, .managedSettings)
        }

        switch readObject(at: settingsURL, fileManager: fileManager) {
        case let .failure(error):
            return make(defaultDays, .defaultValue, error)
        case .success(nil):
            return make(defaultDays, .defaultValue)
        case let .success(object?):
            switch retentionDays(in: object, path: settingsURL.path) {
            case let .failure(error):
                return make(defaultDays, .defaultValue, error)
            case .success(nil):
                return make(defaultDays, .defaultValue)
            case let .success(days?):
                return make(days, .userSettings)
            }
        }
    }

    // MARK: - Raise

    @discardableResult
    static func raiseRetention(
        configDirectory: URL,
        to days: Int = recommendedDays,
        now: Date = Date(),
        fileManager: FileManager = .default,
        beforeWrite: (() -> Void)? = nil
    ) throws -> ClaudeRetentionWriteOutcome {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: configDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ClaudeRetentionSettingsError.directoryMissing(path: configDirectory.path)
        }
        let settingsURL = configDirectory.appendingPathComponent(settingsFileName)
        let target = fileManager.resolvingSymlinkTarget(at: settingsURL)

        for attempt in 0..<2 {
            let original = try readBytes(at: target, reportedPath: settingsURL.path, fileManager: fileManager)
            let newData: Data
            switch try plannedWrite(original: original, days: days, reportedPath: settingsURL.path) {
            case let .alreadySufficient(current):
                return .alreadySufficient(currentDays: current)
            case let .write(data):
                newData = data
            }

            beforeWrite?()
            let current = try readBytes(at: target, reportedPath: settingsURL.path, fileManager: fileManager)
            guard current == original else {
                if attempt == 0 { continue }
                throw ClaudeRetentionSettingsError.changedDuringWrite(path: settingsURL.path)
            }

            let permissions = original == nil ? nil : posixPermissions(of: target, fileManager: fileManager)
            var backupURL: URL?
            if let original {
                backupURL = try writeBackup(
                    original,
                    in: configDirectory,
                    now: now,
                    permissions: permissions,
                    fileManager: fileManager
                )
            }
            do {
                try newData.write(to: target, options: .atomic)
                if let permissions {
                    try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
                }
            } catch {
                throw ClaudeRetentionSettingsError.writeFailed(path: settingsURL.path)
            }
            return .written(backupURL: backupURL)
        }
        throw ClaudeRetentionSettingsError.changedDuringWrite(path: settingsURL.path)
    }

    private enum PlannedWrite {
        case write(Data)
        case alreadySufficient(Int)
    }

    private static func plannedWrite(original: Data?, days: Int, reportedPath: String) throws -> PlannedWrite {
        guard let original else {
            return .write(Data("{\n  \"\(key)\": \(days)\n}\n".utf8))
        }
        let object = try parseObject(original, path: reportedPath).get()
        if let current = try retentionDays(in: object, path: reportedPath).get(), current >= days {
            return .alreadySufficient(current)
        }

        let expected = NSMutableDictionary(dictionary: object)
        expected[key] = NSNumber(value: days)

        if let text = String(data: original, encoding: .utf8),
           let patched = updatedJSONText(text, settingDays: days),
           let data = patched.data(using: .utf8),
           matches(data, expected) {
            return .write(data)
        }
        // The text patch failed or didn't round-trip: re-serialize. Loses formatting, keeps data.
        if var data = try? JSONSerialization.data(withJSONObject: expected, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            data.append(UInt8(ascii: "\n"))
            if matches(data, expected) {
                return .write(data)
            }
        }
        throw ClaudeRetentionSettingsError.verificationFailed(path: reportedPath)
    }

    private static func matches(_ data: Data, _ expected: NSDictionary) -> Bool {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? NSDictionary else {
            return false
        }
        return parsed.isEqual(expected)
    }

    private static func writeBackup(
        _ data: Data,
        in directory: URL,
        now: Date,
        permissions: NSNumber?,
        fileManager: FileManager
    ) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let base = backupPrefix + formatter.string(from: now)

        for index in 1...100 {
            let name = index == 1 ? base : "\(base)-\(index)"
            let url = directory.appendingPathComponent(name)
            do {
                try data.write(to: url, options: .withoutOverwriting)
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                throw ClaudeRetentionSettingsError.writeFailed(path: url.path)
            }
            if let permissions {
                try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            }
            return url
        }
        throw ClaudeRetentionSettingsError.writeFailed(path: directory.appendingPathComponent(base).path)
    }

    private static func posixPermissions(of url: URL, fileManager: FileManager) -> NSNumber? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
    }

    // MARK: - Reading

    /// `nil` when the file doesn't exist (a broken symlink counts as missing).
    private static func readBytes(at url: URL, reportedPath: String, fileManager: FileManager) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ClaudeRetentionSettingsError.unreadable(path: reportedPath)
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
        } catch {
            throw ClaudeRetentionSettingsError.unreadable(path: reportedPath)
        }
        guard data.count <= maximumFileSize else {
            throw ClaudeRetentionSettingsError.tooLarge(path: reportedPath)
        }
        return data
    }

    private static func readObject(at url: URL, fileManager: FileManager) -> Result<[String: Any]?, ClaudeRetentionSettingsError> {
        let data: Data?
        do {
            data = try readBytes(at: url, reportedPath: url.path, fileManager: fileManager)
        } catch let error as ClaudeRetentionSettingsError {
            return .failure(error)
        } catch {
            return .failure(.unreadable(path: url.path))
        }
        guard let data else {
            return .success(nil)
        }
        return parseObject(data, path: url.path).map { Optional($0) }
    }

    private static func parseObject(_ data: Data, path: String) -> Result<[String: Any], ClaudeRetentionSettingsError> {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return .failure(.invalidJSON(path: path))
        }
        // JSONSerialization tolerates trailing commas; strict JSON doesn't, and neither may Claude Code.
        if containsTrailingComma(data) {
            return .failure(.invalidJSON(path: path))
        }
        guard let object = parsed as? [String: Any] else {
            return .failure(.notAnObject(path: path))
        }
        return .success(object)
    }

    /// The top-level value: an integer, or a double with no fractional part. Booleans, strings,
    /// fractions and anything else are `unexpectedValueType`. Missing → `nil`.
    private static func retentionDays(in object: [String: Any], path: String) -> Result<Int?, ClaudeRetentionSettingsError> {
        guard let value = object[key] else {
            return .success(nil)
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return .failure(.unexpectedValueType(path: path))
        }
        if CFNumberIsFloatType(number) {
            let double = number.doubleValue
            guard double.isFinite, double.rounded() == double, let integer = Int(exactly: double) else {
                return .failure(.unexpectedValueType(path: path))
            }
            return .success(integer)
        }
        return .success(Int(clamping: number.int64Value))
    }
}
