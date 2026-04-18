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

extension PaneShellContext {
    var compactPathLabel: String? {
        Self.compactPath(path, home: home)
    }

    var remoteHostLabel: String? {
        guard scope == .remote else {
            return nil
        }

        return host ?? user
    }

    var remotePathLabel: String? {
        guard scope == .remote else {
            return nil
        }

        return compactPathLabel
    }

    var remoteLocationLabel: String? {
        guard scope == .remote else {
            return nil
        }

        switch (remoteHostLabel, remotePathLabel) {
        case let (host?, path?) where !host.isEmpty && !path.isEmpty:
            return "\(host) \(path)"
        case let (host?, _):
            return host
        case let (_, path?):
            return path
        case (nil, nil):
            return nil
        }
    }

    var borderContextDisplayText: String? {
        switch scope {
        case .local:
            guard let compactPath = compactPathLabel else {
                return nil
            }
            if compactPath == "~" {
                let identity = [user, host].compactMap { $0 }.joined(separator: "@")
                if !identity.isEmpty {
                    return "\(identity):\(compactPath)"
                }
            }
            return compactPath
        case .remote:
            return remoteLocationLabel
        }
    }

    private static func compactPath(_ path: String?, home: String?) -> String? {
        guard let path, !path.isEmpty else {
            return nil
        }

        guard let home, !home.isEmpty, path.hasPrefix(home) else {
            return path
        }

        if path == home {
            return "~"
        }

        return path.replacingOccurrences(of: home, with: "~", options: [.anchored])
    }
}
