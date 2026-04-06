import Foundation

struct AboutMetadata: Equatable, Sendable {
    static let gitCommitKey = "ZenttyGitCommit"

    let version: String
    let build: String
    let commit: String

    init(version: String, build: String, commit: String) {
        self.version = version
        self.build = build
        self.commit = commit
    }

    init?(infoDictionary: [String: Any]) {
        self.init(
            version: Self.trimmedValue(for: "CFBundleShortVersionString", in: infoDictionary) ?? "Unknown",
            build: Self.trimmedValue(for: "CFBundleVersion", in: infoDictionary) ?? "Unknown",
            commit: Self.trimmedValue(for: Self.gitCommitKey, in: infoDictionary) ?? "unknown"
        )
    }

    static func load(from bundle: Bundle) -> AboutMetadata {
        AboutMetadata(infoDictionary: bundle.infoDictionary ?? [:])
            ?? AboutMetadata(version: "Unknown", build: "Unknown", commit: "unknown")
    }

    private static func trimmedValue(for key: String, in infoDictionary: [String: Any]) -> String? {
        guard let rawValue = infoDictionary[key] as? String else {
            return nil
        }

        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
