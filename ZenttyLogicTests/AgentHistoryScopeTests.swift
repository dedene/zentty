import Foundation
import XCTest
@testable import Zentty

final class AgentHistoryScopeTests: XCTestCase {
    private let home = "/Users/tester"

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func resolve(
        cwd: String?,
        repoRoot: String? = nil,
        isRemote: Bool = false,
        homeDirectory: String? = nil,
        identities: [String: RepositoryIdentity] = [:]
    ) throws -> AgentHistoryProjectScope {
        try AgentHistoryProjectScopeResolver.resolve(
            cwd: cwd,
            repoRoot: repoRoot,
            isRemote: isRemote,
            homeDirectory: homeDirectory ?? home,
            identity: { identities[$0] }
        )
    }

    private func scope(_ key: String, allowsCWDPrefix: Bool = true) -> AgentHistoryProjectScope {
        AgentHistoryProjectScope(
            key: key,
            displayName: (key as NSString).lastPathComponent,
            allowsCWDPrefix: allowsCWDPrefix
        )
    }

    // MARK: - Resolve

    func test_linked_worktree_pane_scopes_to_main_repo_root() throws {
        let identity = RepositoryIdentity(
            repoRoot: "/nonexistent-zt/worktrees/app-feature",
            mainRepoRoot: "/nonexistent-zt/src/app",
            isLinkedWorktree: true,
            headBranch: "feature"
        )
        let resolved = try resolve(
            cwd: "/nonexistent-zt/worktrees/app-feature/Sources",
            repoRoot: "/nonexistent-zt/worktrees/app-feature",
            identities: ["/nonexistent-zt/worktrees/app-feature": identity]
        )
        XCTAssertEqual(resolved.key, "/nonexistent-zt/src/app")
        XCTAssertEqual(resolved.displayName, "app")
        XCTAssertTrue(resolved.allowsCWDPrefix)
    }

    func test_repo_pane_scopes_to_repo_root() throws {
        // No identity on disk: the pane's repo root wins over its cwd.
        let resolved = try resolve(cwd: "/nonexistent-zt/src/app/Sources/Core", repoRoot: "/nonexistent-zt/src/app")
        XCTAssertEqual(resolved.key, "/nonexistent-zt/src/app")
        XCTAssertEqual(resolved.displayName, "app")

        // A plain repository identity keeps the repo root.
        let identity = RepositoryIdentity(
            repoRoot: "/nonexistent-zt/src/app",
            mainRepoRoot: "/nonexistent-zt/src/app",
            isLinkedWorktree: false,
            headBranch: "main"
        )
        let withIdentity = try resolve(
            cwd: "/nonexistent-zt/src/app/Sources",
            repoRoot: "/nonexistent-zt/src/app/",
            identities: ["/nonexistent-zt/src/app": identity]
        )
        XCTAssertEqual(withIdentity.key, "/nonexistent-zt/src/app")
    }

    func test_non_repo_pane_scopes_to_cwd_with_prefix() throws {
        let resolved = try resolve(cwd: "/nonexistent-zt/scratch/notes")
        XCTAssertEqual(resolved.key, "/nonexistent-zt/scratch/notes")
        XCTAssertEqual(resolved.displayName, "notes")
        XCTAssertTrue(resolved.allowsCWDPrefix)
        XCTAssertTrue(resolved.admits(repoRoot: nil, mainRepoRoot: nil, cwd: "/nonexistent-zt/scratch/notes/sub"))
    }

    func test_home_pane_scopes_to_exact_cwd_only() throws {
        let resolved = try resolve(cwd: home)
        XCTAssertEqual(resolved.key, home)
        XCTAssertEqual(resolved.displayName, "tester")
        XCTAssertFalse(resolved.allowsCWDPrefix)
        XCTAssertTrue(resolved.admits(repoRoot: nil, mainRepoRoot: nil, cwd: home))
        XCTAssertFalse(resolved.admits(repoRoot: nil, mainRepoRoot: nil, cwd: home + "/scratch"))

        // `~` expands to the same home scope.
        XCTAssertEqual(try resolve(cwd: "~"), resolved)
    }

    func test_root_and_home_ancestors_never_allow_prefix() throws {
        let root = try resolve(cwd: "/")
        XCTAssertEqual(root.key, "/")
        XCTAssertEqual(root.displayName, "/")
        XCTAssertFalse(root.allowsCWDPrefix)
        XCTAssertTrue(root.admits(repoRoot: nil, mainRepoRoot: nil, cwd: "/"))
        XCTAssertFalse(root.admits(repoRoot: nil, mainRepoRoot: nil, cwd: "/etc"))

        let users = try resolve(cwd: "/Users")
        XCTAssertFalse(users.allowsCWDPrefix)
        XCTAssertFalse(users.admits(repoRoot: nil, mainRepoRoot: nil, cwd: home))

        // A sibling of home that only shares a string prefix is not an ancestor.
        let sibling = try resolve(cwd: "/Users/test")
        XCTAssertTrue(sibling.allowsCWDPrefix)

        // A folder below home still allows the prefix.
        let below = try resolve(cwd: home + "/scratch")
        XCTAssertTrue(below.allowsCWDPrefix)

        // A repo at home (dotfiles) is still home: no prefix.
        let dotfiles = try resolve(cwd: home + "/.config", repoRoot: home)
        XCTAssertEqual(dotfiles.key, home)
        XCTAssertFalse(dotfiles.allowsCWDPrefix)
    }

    func test_remote_pane_and_missing_cwd_are_refused() {
        XCTAssertThrowsError(try resolve(cwd: "/nonexistent-zt/src/app", isRemote: true)) { error in
            XCTAssertEqual(error as? AgentHistoryScopeUnavailable, .remotePane)
        }
        XCTAssertThrowsError(try resolve(cwd: nil)) { error in
            XCTAssertEqual(error as? AgentHistoryScopeUnavailable, .noDirectory)
        }
        XCTAssertThrowsError(try resolve(cwd: "   ", repoRoot: "")) { error in
            XCTAssertEqual(error as? AgentHistoryScopeUnavailable, .noDirectory)
        }
        XCTAssertThrowsError(try resolve(cwd: "relative/path")) { error in
            XCTAssertEqual(error as? AgentHistoryScopeUnavailable, .noDirectory)
        }
        // Remote wins over a missing directory: the pane's project is unknown either way.
        XCTAssertThrowsError(try resolve(cwd: nil, isRemote: true)) { error in
            XCTAssertEqual(error as? AgentHistoryScopeUnavailable, .remotePane)
        }
    }

    func test_symlinked_cwd_is_canonicalized() throws {
        let directory = try makeDirectory()
        let real = directory.appendingPathComponent("real-project", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("linked-project")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let fakeHome = directory.appendingPathComponent("home").path
        var asked: [String] = []
        let resolved = try AgentHistoryProjectScopeResolver.resolve(
            cwd: link.path + "/",
            repoRoot: nil,
            isRemote: false,
            homeDirectory: fakeHome,
            identity: { asked.append($0); return nil }
        )
        let expected = AgentHistoryPath.canonical(real.path, homeDirectory: fakeHome)
        XCTAssertEqual(resolved.key, expected)
        XCTAssertEqual(resolved.displayName, "real-project")
        XCTAssertTrue(resolved.allowsCWDPrefix)
        // The identity lookup sees the canonical folder, not the symlink.
        XCTAssertEqual(asked, [expected])
    }

    // MARK: - Admits

    func test_admits_by_main_repo_root_repo_root_and_repo_less_cwd() {
        let project = scope("/src/app")
        // Linked worktree of the project.
        XCTAssertTrue(project.admits(repoRoot: "/wt/app-feature", mainRepoRoot: "/src/app", cwd: "/wt/app-feature"))
        // The main tree itself.
        XCTAssertTrue(project.admits(repoRoot: "/src/app", mainRepoRoot: "/src/app", cwd: "/src/app/Sources"))
        // Repo root only (main repo root unknown).
        XCTAssertTrue(project.admits(repoRoot: "/src/app", mainRepoRoot: nil, cwd: "/src/app"))
        // Repo-less sessions at or below the key.
        XCTAssertTrue(project.admits(repoRoot: nil, mainRepoRoot: nil, cwd: "/src/app"))
        XCTAssertTrue(project.admits(repoRoot: nil, mainRepoRoot: nil, cwd: "/src/app/build"))
        // A different repository whose folder sits below the key is its own project.
        XCTAssertFalse(project.admits(repoRoot: "/src/app/vendor/lib", mainRepoRoot: "/src/app/vendor/lib", cwd: "/src/app/vendor/lib"))
        // No location at all.
        XCTAssertFalse(project.admits(repoRoot: nil, mainRepoRoot: nil, cwd: nil))
        // Other projects.
        XCTAssertFalse(project.admits(repoRoot: "/src/other", mainRepoRoot: "/src/other", cwd: "/src/other"))
    }

    func test_sibling_directory_prefix_is_not_admitted() {
        let project = scope("/src/app")
        XCTAssertFalse(project.admits(repoRoot: nil, mainRepoRoot: nil, cwd: "/src/app-old"))
        XCTAssertFalse(project.admits(repoRoot: nil, mainRepoRoot: nil, cwd: "/src/apple/x"))
        XCTAssertFalse(project.admits(repoRoot: "/src/app-old", mainRepoRoot: "/src/app-old", cwd: "/src/app-old"))
        XCTAssertFalse(project.admits(repoRoot: nil, mainRepoRoot: nil, cwd: "/src"))
    }

    func test_repo_sessions_under_home_not_admitted_by_home_scope() throws {
        let homeScope = try resolve(cwd: home)
        XCTAssertFalse(homeScope.admits(
            repoRoot: home + "/src/app", mainRepoRoot: home + "/src/app", cwd: home + "/src/app"
        ))
        XCTAssertFalse(homeScope.admits(repoRoot: nil, mainRepoRoot: nil, cwd: home + "/Downloads"))
        XCTAssertTrue(homeScope.admits(repoRoot: nil, mainRepoRoot: nil, cwd: home))
        // A dotfiles repository rooted at home is the home project.
        XCTAssertTrue(homeScope.admits(repoRoot: home, mainRepoRoot: home, cwd: home + "/.config"))
    }

    // MARK: - SQL

    func test_sql_predicate_matches_admits_on_fixture_rows() throws {
        let directory = try makeDirectory()
        let database = try AgentHistoryDatabase(
            url: directory.appendingPathComponent("scope.sqlite"),
            mode: .readWrite,
            busyTimeoutMilliseconds: 2_000
        )
        addTeardownBlock { database.close() }
        try database.execute(
            "CREATE TABLE sessions(id INTEGER PRIMARY KEY, main_repo_root TEXT, repo_root TEXT, cwd TEXT)"
        )

        let rows: [(main: String?, repo: String?, cwd: String?)] = [
            ("/src/app", "/src/app", "/src/app"),
            ("/src/app", "/wt/app-feature", "/wt/app-feature/Sources"),
            (nil, "/src/app", "/src/app/x"),
            (nil, nil, "/src/app"),
            (nil, nil, "/src/app/build"),
            (nil, nil, "/src/app-old"),
            (nil, nil, "/src/apple/x"),
            (nil, nil, "/src"),
            (nil, nil, nil),
            ("/src/app/vendor/lib", "/src/app/vendor/lib", "/src/app/vendor/lib"),
            ("/src/other", "/src/other", "/src/app"),
            (nil, nil, "/"),
            (nil, nil, "/etc"),
            (nil, nil, home),
            (nil, nil, home + "/notes"),
            (home, home, home + "/.config"),
            (home + "/src/app", home + "/src/app", home + "/src/app"),
            (nil, nil, "/src/100%_done"),
            (nil, nil, "/src/100%_done/sub"),
            (nil, nil, "/src/100%Xdone/sub"),
            (nil, nil, "/src/café"),
            (nil, nil, "/src/café/ünïcode"),
            (nil, nil, "/src/cafe/x"),
        ]
        for (index, row) in rows.enumerated() {
            try database.run(
                "INSERT INTO sessions(id, main_repo_root, repo_root, cwd) VALUES (?, ?, ?, ?)",
                [.integer(Int64(index + 1)), .of(row.main), .of(row.repo), .of(row.cwd)]
            )
        }

        let scopes = [
            scope("/src/app"),
            scope("/src/app", allowsCWDPrefix: false),
            scope("/", allowsCWDPrefix: false),
            scope(home, allowsCWDPrefix: false),
            scope("/src/100%_done"),
            scope("/src/café"),
            scope("/src"),
            scope("/nowhere"),
        ]
        for projectScope in scopes {
            let predicate = projectScope.sqlPredicate(sessionAlias: "s")
            // The predicate is appended to an outer statement that already binds `?`s.
            let sql = "SELECT s.id FROM sessions s WHERE s.id > ? AND \(predicate.sql) AND s.id < ? ORDER BY s.id"
            let bindings: [AgentHistoryValue] = [.integer(0)] + predicate.bindings + [.integer(1_000)]
            let selected = try database.query(sql, bindings) { $0.int64(0) }
            let expected = rows.enumerated().compactMap { index, row in
                projectScope.admits(repoRoot: row.repo, mainRepoRoot: row.main, cwd: row.cwd) ? Int64(index + 1) : nil
            }
            XCTAssertEqual(selected, expected, "scope \(projectScope.key) prefix=\(projectScope.allowsCWDPrefix)")
        }

        // Sanity: the fixture exercises both outcomes.
        let app = scope("/src/app")
        let admitted = rows.filter { app.admits(repoRoot: $0.repo, mainRepoRoot: $0.main, cwd: $0.cwd) }
        XCTAssertEqual(admitted.count, 5)

        // The alias is honoured.
        XCTAssertTrue(app.sqlPredicate(sessionAlias: "x").sql.contains("x.main_repo_root"))
        XCTAssertFalse(app.sqlPredicate(sessionAlias: "x").sql.contains("s."))
    }
}
