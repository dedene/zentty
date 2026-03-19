import Foundation

enum PaneShellContextScope: String, Equatable, Sendable {
    case local
    case remote
}

struct PaneShellContext: Equatable, Sendable {
    let scope: PaneShellContextScope
    let path: String?
    let home: String?
    let user: String?
    let host: String?

    init(
        scope: PaneShellContextScope,
        path: String?,
        home: String?,
        user: String?,
        host: String?
    ) {
        self.scope = scope
        self.path = Self.trimmed(path)
        self.home = Self.trimmed(home)
        self.user = Self.trimmed(user)
        self.host = Self.trimmed(host)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }
}
