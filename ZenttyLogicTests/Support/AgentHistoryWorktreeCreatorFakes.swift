import Foundation
@testable import Zentty

/// The worktree folder and the main repository's worktree registrations
/// (`<main>/.git/worktrees/<name>/{gitdir,locked}`) as the creator sees them. In memory only;
/// guarded by `lock`.
final class FakeWorktreeDisk: @unchecked Sendable {
    private struct Registration {
        var gitdir: String
        var locked: String?
    }

    private let lock = NSLock()
    private let folderPath: String
    private let gitDirectory: String
    private var folderPresent: Bool
    private var registrations: [String: Registration] = [:]

    init(path: String = "", mainRepoRoot: String = "/fake-main-repo", exists: Bool = false) {
        folderPath = path
        gitDirectory = mainRepoRoot + "/.git"
        folderPresent = exists
    }

    private var worktreesDirectory: String { gitDirectory + "/worktrees" }

    func exists(at candidate: String) -> Bool {
        lock.withLock { folderPresent && candidate == folderPath }
    }

    func setExists(_ value: Bool) {
        lock.withLock { folderPresent = value }
    }

    /// Registers a worktree the way `git worktree add` does: `gitdir` holds `<worktree>/.git`.
    func register(_ name: String, worktree: String, locked: String? = nil) {
        lock.withLock { registrations[name] = Registration(gitdir: worktree + "/.git", locked: locked) }
    }

    func unlockRegistrations(pointingAt worktree: String) {
        lock.withLock {
            for (name, registration) in registrations where registration.gitdir == worktree + "/.git" {
                registrations[name]?.locked = nil
            }
        }
    }

    func removeRegistrations(pointingAt worktree: String) {
        lock.withLock {
            registrations = registrations.filter { $0.value.gitdir != worktree + "/.git" }
        }
    }

    var registrationNames: [String] {
        lock.withLock { registrations.keys.sorted() }
    }

    func isLocked(_ name: String) -> Bool {
        lock.withLock { registrations[name]?.locked != nil }
    }
}

extension FakeWorktreeDisk: AgentHistoryFileSystemProbing {
    func isDirectory(_ path: String) -> Bool {
        lock.withLock {
            if path == gitDirectory || path == worktreesDirectory || (folderPresent && path == folderPath) {
                return true
            }
            guard let name = registrationName(path) else { return false }
            return registrations[name] != nil
        }
    }

    func fileExists(_ path: String) -> Bool {
        isDirectory(path) || contents(path) != nil
    }

    func contents(_ path: String) -> String? {
        lock.withLock {
            let parent = (path as NSString).deletingLastPathComponent
            guard let name = registrationName(parent), let registration = registrations[name] else {
                return nil
            }
            switch (path as NSString).lastPathComponent {
            case "gitdir": return registration.gitdir + "\n"
            case "locked": return registration.locked
            default: return nil
            }
        }
    }

    func directoryEntries(_ path: String) -> [String] {
        lock.withLock { path == worktreesDirectory ? registrations.keys.sorted() : [] }
    }

    /// `<main>/.git/worktrees/<name>` → `name`; caller holds `lock`.
    private func registrationName(_ path: String) -> String? {
        let prefix = worktreesDirectory + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let name = String(path.dropFirst(prefix.count))
        return name.isEmpty || name.contains("/") ? nil : name
    }
}

struct WorktreeCreatorCall: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
    let terminationGracePeriod: TimeInterval
}

/// Collects runner calls from the creator's background queue; guarded by `lock`.
final class WorktreeCreatorCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [WorktreeCreatorCall] = []

    func record(_ call: WorktreeCreatorCall) {
        lock.withLock { storage.append(call) }
    }

    var calls: [WorktreeCreatorCall] {
        lock.withLock { storage }
    }

    /// Arguments after `git` of every `/usr/bin/env git …` call.
    var gitArguments: [[String]] {
        calls.filter { $0.executable == "/usr/bin/env" }.map { Array($0.arguments.dropFirst()) }
    }
}

/// Hands the completion's result back to the test thread; guarded by `lock`.
final class WorktreeCreatorResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Void, AgentHistoryWorktreeError>?

    func set(_ result: Result<Void, AgentHistoryWorktreeError>) {
        lock.withLock { stored = result }
    }

    var value: Result<Void, AgentHistoryWorktreeError>? {
        lock.withLock { stored }
    }
}

extension Result where Failure == AgentHistoryWorktreeError {
    var failure: AgentHistoryWorktreeError? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
