import Foundation
import XCTest
@testable import Zentty

/// The committed synthetic ranking golden set (spec §11.3): a small corpus whose sessions pair up
/// around one ranking rule each, and the query that must put a given session first. Every rule
/// is set up so the expected session would lose without it (it is older, opened less, or only
/// one of several hits), which makes a ranking regression show up as a wrong top-1.
///
/// Each case uses its own vocabulary, so a query only reaches the sessions built for it.
enum HistoryRankingGoldenFixture {
    struct Message {
        var role: AgentHistoryRole = .user
        var daysAgo: Double
        var text: String
    }

    struct Session {
        let nativeID: String
        var agent: AgentHistoryAgent = .claude
        var title: String
        var repo: String?
        var cwd: String?
        var branch: String?
        var updatedDaysAgo: Double
        var archived = false
        var opens = 0
        var lastOpenedDaysAgo: Double?
        var messages: [Message]
        var pathArtifacts: [String] = []
    }

    struct Case {
        let name: String
        let query: String
        let expectedNativeID: String
        var currentRepositoryKey: String?
        var scopeKey: String?
    }

    static let reposRoot = "/golden/repos"

    static func repo(_ name: String) -> String { "\(reposRoot)/\(name)" }

    /// One user message at the session's own update time.
    private static func said(_ text: String, _ daysAgo: Double) -> [Message] {
        [Message(daysAgo: daysAgo, text: text)]
    }

    // MARK: - Sessions

    static let sessions: [Session] = [
        // Whole word beats a fresher, often-opened mid-word hit (word-level gate).
        Session(nativeID: "cache-word", title: "Edge invalidation", repo: repo("api"), updatedDaysAgo: 40,
                messages: said("invalidate the cache after each rollout", 40)),
        Session(nativeID: "cache-midword", agent: .codex, title: "Launch warmup", repo: repo("api"),
                updatedDaysAgo: 1, opens: 5, lastOpenedDaysAgo: 1,
                messages: said("warm the precache before launch", 1)),

        // Whole word beats a fresher word prefix.
        Session(nativeID: "token-word", title: "Credential expiry", updatedDaysAgo: 6,
                messages: said("rotate the token on expiry", 6)),
        Session(nativeID: "token-prefix", title: "Emoji input", updatedDaysAgo: 2,
                messages: said("the tokenizer drops emoji", 2)),

        // Typed-order phrase (+0.25) beats terms that are only close together (+0.1).
        Session(nativeID: "phrase-exact", title: "Staging outage", updatedDaysAgo: 5,
                messages: said("the retry budget is exhausted on staging", 5)),
        Session(nativeID: "phrase-scattered", title: "Overnight jobs", updatedDaysAgo: 3,
                messages: said("the budget allows one more retry tonight", 3)),

        // A short commit hash is a word prefix of the full hash; inside a longer hex digest it
        // gets no credit at all.
        Session(nativeID: "hex-commit", title: "Backport", updatedDaysAgo: 15,
                messages: said("cherry-pick a3f9c1e7b2 onto main", 15)),
        Session(nativeID: "hex-embedded", agent: .grok, title: "Artifact digest", updatedDaysAgo: 1, opens: 3,
                lastOpenedDaysAgo: 1, messages: said("digest 0deadbeefa3f9c1e7 mismatch after upload", 1)),

        // A changed file's path segment is a whole word (artifact discount 0.9).
        Session(nativeID: "path-artifact", title: "Window tidy-up", repo: repo("desktop"), updatedDaysAgo: 12,
                messages: said("tidy up the window code", 12),
                pathArtifacts: ["Sources/UI/WindowCoordinator.swift"]),
        Session(nativeID: "path-midword", title: "Tab subclass", repo: repo("desktop"), updatedDaysAgo: 1,
                messages: said("subclass MainWindowCoordinator for tabs", 1)),

        // A whole-word branch match stays word-level despite the 0.6 field weight.
        Session(nativeID: "branch-only", title: "Worker cleanup", repo: repo("worker"),
                branch: "feature/zephyr-sync", updatedDaysAgo: 20,
                messages: said("clean up the sync worker", 20)),
        Session(nativeID: "zephyr-midword", title: "Noisy flag", updatedDaysAgo: 1,
                messages: said("the antizephyr flag is noisy", 1)),

        // Title (1.0) beats repo name (0.4) even against a much fresher session.
        Session(nativeID: "billing-title", title: "Billing export to CSV", updatedDaysAgo: 20,
                messages: said("export the invoices", 20)),
        Session(nativeID: "billing-repo", title: "Upgrade dependencies", repo: repo("billing"), updatedDaysAgo: 1,
                messages: said("bump the lockfile", 1)),

        // The folder name of a repo-less session is a word-level match (weight 0.3).
        Session(nativeID: "folder-match", agent: .opencode, title: "Shell config", cwd: "/Users/golden/dotfiles",
                updatedDaysAgo: 25, messages: said("symlink the zsh config", 25)),
        Session(nativeID: "dotfiles-midword", title: "Nightly backup", updatedDaysAgo: 1,
                messages: said("sync mydotfiles backup nightly", 1)),

        // More hits at the best quality beat one, even a little fresher.
        Session(nativeID: "many-hits", title: "Schema moves", updatedDaysAgo: 4, messages: [
            Message(daysAgo: 4.2, text: "migrate the users table"),
            Message(daysAgo: 4.1, text: "migrate the orders table"),
            Message(daysAgo: 4, text: "migrate the audit table"),
        ]),
        Session(nativeID: "one-hit", title: "Schema move", updatedDaysAgo: 3.5,
                messages: said("migrate the sessions table", 3.5)),

        // Every term must match: the fresher session lacks one.
        Session(nativeID: "all-terms", title: "Redis probes", updatedDaysAgo: 9,
                messages: said("add a docker healthcheck for redis", 9)),
        Session(nativeID: "partial-terms", title: "Compose failure", updatedDaysAgo: 1,
                messages: said("docker compose up fails", 1)),

        // Same text: the fresher session wins.
        Session(nativeID: "recent", title: "Startup profile", updatedDaysAgo: 2,
                messages: said("capture a flamegraph of startup", 2)),
        Session(nativeID: "stale", title: "Startup profile", updatedDaysAgo: 45,
                messages: said("capture a flamegraph of startup", 45)),

        // Archived (×0.8) loses to a slightly older live session.
        Session(nativeID: "archived", title: "Launch prompt", updatedDaysAgo: 1, archived: true,
                messages: said("keychain prompt on launch", 1)),
        Session(nativeID: "live-keychain", title: "Launch prompt", updatedDaysAgo: 6,
                messages: said("keychain prompt on launch", 6)),

        // Recent opens outweigh age.
        Session(nativeID: "opened-often", title: "Feed bump", updatedDaysAgo: 30, opens: 6, lastOpenedDaysAgo: 1,
                messages: said("bump the sparkle appcast feed", 30)),
        Session(nativeID: "never-opened", title: "Feed bump", updatedDaysAgo: 3,
                messages: said("bump the sparkle appcast feed", 3)),

        // Repo boost (×1.2) for the current repository with scope "All projects".
        Session(nativeID: "other-repo", title: "Test hygiene", repo: repo("web"), updatedDaysAgo: 3,
                messages: said("quarantine the flaky test", 3)),
        Session(nativeID: "current-repo", title: "Test hygiene", repo: repo("app"), updatedDaysAgo: 4,
                messages: said("quarantine the flaky test", 4)),

        // agent: filter.
        Session(nativeID: "lint-claude", title: "Warnings", updatedDaysAgo: 1,
                messages: said("fix the lint warnings", 1)),
        Session(nativeID: "lint-codex", agent: .codex, title: "Warnings", updatedDaysAgo: 10,
                messages: said("fix the lint warnings", 10)),

        // repo: filter.
        Session(nativeID: "refund-payments", title: "Webhook duplicates", repo: repo("payments"), updatedDaysAgo: 15,
                messages: said("refund webhook fires twice", 15)),
        Session(nativeID: "refund-shop", title: "Webhook duplicates", repo: repo("shop"), updatedDaysAgo: 1,
                messages: said("refund webhook fires twice", 1)),

        // Project scope admits only the current project.
        Session(nativeID: "changelog-app", title: "Release prep", repo: repo("app"), updatedDaysAgo: 20,
                messages: said("draft the changelog", 20)),
        Session(nativeID: "changelog-web", title: "Release prep", repo: repo("web"), updatedDaysAgo: 1,
                messages: said("draft the changelog", 1)),

        // Diacritics fold at ingest and query time; the folded whole word beats a fresher prefix.
        Session(nativeID: "accented", title: "Upload parser", updatedDaysAgo: 8,
                messages: said("the résumé parser chokes on tables", 8)),
        Session(nativeID: "resumes-prefix", title: "Upload speed", updatedDaysAgo: 1,
                messages: said("resumes upload is slow", 1)),

        // A short term needs a whole word or prefix: "ui" inside "build" does not count.
        Session(nativeID: "short-word", title: "Contrast pass", updatedDaysAgo: 7,
                messages: said("dark ui contrast is too low", 7)),
        Session(nativeID: "short-missing", title: "Theme build", updatedDaysAgo: 1,
                messages: said("dark theme build is broken", 1)),
    ]

    // MARK: - Cases

    static let cases: [Case] = [
        Case(name: "word beats fresher mid-word", query: "cache", expectedNativeID: "cache-word"),
        Case(name: "word beats fresher prefix", query: "token", expectedNativeID: "token-word"),
        Case(name: "typed phrase beats proximity", query: "retry budget", expectedNativeID: "phrase-exact"),
        Case(name: "quoted phrase", query: "\"retry budget\"", expectedNativeID: "phrase-exact"),
        Case(name: "short hex commit", query: "a3f9c1e", expectedNativeID: "hex-commit"),
        Case(name: "path artifact segment", query: "windowcoordinator", expectedNativeID: "path-artifact"),
        Case(name: "branch-only match", query: "zephyr", expectedNativeID: "branch-only"),
        Case(name: "title beats repo name", query: "billing", expectedNativeID: "billing-title"),
        Case(name: "folder of repo-less session", query: "dotfiles", expectedNativeID: "folder-match"),
        Case(name: "more best-quality hits", query: "migrate", expectedNativeID: "many-hits"),
        Case(name: "all terms required", query: "docker healthcheck", expectedNativeID: "all-terms"),
        Case(name: "recency", query: "flamegraph", expectedNativeID: "recent"),
        Case(name: "archived penalty", query: "keychain prompt", expectedNativeID: "live-keychain"),
        Case(name: "recent opens", query: "sparkle", expectedNativeID: "opened-often"),
        Case(name: "repo boost", query: "quarantine", expectedNativeID: "current-repo",
             currentRepositoryKey: repo("app")),
        Case(name: "no repo boost without current repo", query: "quarantine", expectedNativeID: "other-repo"),
        Case(name: "agent filter", query: "agent:codex lint", expectedNativeID: "lint-codex"),
        Case(name: "agent control", query: "lint", expectedNativeID: "lint-claude"),
        Case(name: "repo filter", query: "repo:payments refund", expectedNativeID: "refund-payments"),
        Case(name: "repo control", query: "refund", expectedNativeID: "refund-shop"),
        Case(name: "project scope", query: "changelog", expectedNativeID: "changelog-app", scopeKey: repo("app")),
        Case(name: "diacritics fold", query: "resume", expectedNativeID: "accented"),
        Case(name: "short term needs a word", query: "dark ui", expectedNativeID: "short-word"),
    ]

    // MARK: - Building

    /// Inserts every golden session into `fixture`; returns session row ids by native id.
    @discardableResult
    static func populate(_ fixture: HistorySearchFixture) throws -> [String: Int64] {
        var ids: [String: Int64] = [:]
        for session in sessions {
            let id = try fixture.addSession(
                session.nativeID, agent: session.agent, title: session.title,
                cwd: session.cwd ?? session.repo, repo: session.repo, mainRepo: session.repo,
                branch: session.branch, updatedDaysAgo: session.updatedDaysAgo, archived: session.archived,
                opens: session.opens, lastOpenedDaysAgo: session.lastOpenedDaysAgo)
            for message in session.messages {
                try fixture.addMessage(session: id, role: message.role, daysAgo: message.daysAgo, text: message.text)
            }
            for path in session.pathArtifacts {
                try fixture.addArtifact(session: id, kind: .path, value: path, daysAgo: session.updatedDaysAgo)
            }
            ids[session.nativeID] = id
        }
        return ids
    }

    static func context(for goldenCase: Case, fixture: HistorySearchFixture) -> HistorySearchContext {
        let scope = goldenCase.scopeKey.map { HistorySearchFixture.projectScope($0) } ?? .all
        return fixture.context(scope, currentRepositoryKey: goldenCase.currentRepositoryKey)
    }
}
