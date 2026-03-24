import XCTest
@testable import Zentty

@MainActor
final class WorkspaceGitContextResolverTests: XCTestCase {
    func test_resolve_reports_repo_root_and_branch_for_nested_repository_path() async throws {
        let repositoryURL = try makeRepository()
        let nestedURL = repositoryURL.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)

        let resolver = WorkspaceGitContextResolver()
        let resolvedContext = await resolver.resolve(path: nestedURL.path)
        let context = try XCTUnwrap(resolvedContext)
        let canonicalRepositoryRoot = repositoryURL.resolvingSymlinksInPath().standardizedFileURL.path

        XCTAssertEqual(context.repoRoot, canonicalRepositoryRoot)
        XCTAssertEqual(context.branchName, "main")
        XCTAssertEqual(context.branchDisplayText, "main")
        XCTAssertFalse(context.isDetached)
    }

    func test_resolve_reports_short_sha_when_head_is_detached() async throws {
        let repositoryURL = try makeRepository()
        try runGit(["checkout", "--detach"], in: repositoryURL)

        let resolver = WorkspaceGitContextResolver()
        let resolvedContext = await resolver.resolve(path: repositoryURL.path)
        let context = try XCTUnwrap(resolvedContext)

        XCTAssertNil(context.branchName)
        XCTAssertTrue(context.isDetached)
        XCTAssertTrue(context.branchDisplayText.hasSuffix(" (detached)"))
        XCTAssertEqual(context.branchDisplayText.split(separator: " ").first?.count, 7)
    }

    private func makeRepository() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: rootURL)
        try runGit(["config", "user.email", "peter@example.com"], in: rootURL)
        try runGit(["config", "user.name", "Peter"], in: rootURL)
        let fileURL = rootURL.appendingPathComponent("README.md")
        try Data("hello\n".utf8).write(to: fileURL)
        try runGit(["add", "README.md"], in: rootURL)
        try runGit(["commit", "-m", "init"], in: rootURL)
        return rootURL
    }

    private func runGit(_ arguments: [String], in directoryURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directoryURL

        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(message)")
        }
    }
}
