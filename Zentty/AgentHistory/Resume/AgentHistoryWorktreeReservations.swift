import Foundation

/// Worktree paths a History resume is recreating, held from the start of `git worktree add` until
/// the session launches in it (or the recreation fails). While git runs the folder already
/// exists, so without this a second resume would see the session's folder as ready and launch an
/// agent into an unfinished checkout, or start a second `add` on the same path. One set for the
/// whole process, so every window shares it.
@MainActor
final class AgentHistoryWorktreeReservations {
    static let shared = AgentHistoryWorktreeReservations()

    private var paths: Set<String> = []

    init() {}

    /// False when the path, or a folder around it, is already reserved.
    func reserve(_ worktreePath: String) -> Bool {
        guard !isReserved(containing: worktreePath) else {
            return false
        }
        paths.insert(AgentHistoryFolderResolver.canonicalPath(worktreePath))
        return true
    }

    func release(_ worktreePath: String) {
        paths.remove(AgentHistoryFolderResolver.canonicalPath(worktreePath))
    }

    /// True when `directory` is a reserved worktree or lies inside one.
    func isReserved(containing directory: String) -> Bool {
        let candidate = AgentHistoryFolderResolver.canonicalPath(directory)
        return paths.contains { reserved in
            candidate == reserved || candidate.hasPrefix(reserved == "/" ? "/" : reserved + "/")
        }
    }
}
