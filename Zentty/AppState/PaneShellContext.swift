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
    let gitBranch: String?

    init(
        scope: PaneShellContextScope,
        path: String?,
        home: String?,
        user: String?,
        host: String?
    ) {
        self.init(
            scope: scope,
            path: path,
            home: home,
            user: user,
            host: host,
            gitBranch: nil
        )
    }

    init(
        scope: PaneShellContextScope,
        path: String?,
        home: String?,
        user: String?,
        host: String?,
        gitBranch: String? = nil
    ) {
        self.scope = scope
        self.path = Self.trimmed(path)
        self.home = Self.trimmed(home)
        self.user = Self.trimmed(user)
        self.host = Self.trimmed(host)
        self.gitBranch = Self.trimmed(gitBranch)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }
}
