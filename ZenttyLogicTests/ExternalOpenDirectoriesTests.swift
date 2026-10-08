import XCTest
@testable import Zentty

final class ExternalOpenDirectoriesTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalOpenDirectoriesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func test_folder_resolves_to_itself() throws {
        let folder = try makeDirectory("project")

        XCTAssertEqual(ExternalOpenDirectories.resolve([folder]), [folder.standardizedFileURL.path])
    }

    func test_file_resolves_to_its_parent_folder() throws {
        let folder = try makeDirectory("project")
        let file = folder.appendingPathComponent("README.md")
        try Data("hi".utf8).write(to: file)

        XCTAssertEqual(ExternalOpenDirectories.resolve([file]), [folder.standardizedFileURL.path])
    }

    func test_missing_paths_and_non_file_urls_are_dropped() throws {
        let missing = rootURL.appendingPathComponent("gone", isDirectory: true)
        let web = try XCTUnwrap(URL(string: "https://example.com/project"))

        XCTAssertEqual(ExternalOpenDirectories.resolve([missing, web]), [])
    }

    func test_duplicates_collapse_and_order_is_kept() throws {
        let first = try makeDirectory("first")
        let second = try makeDirectory("second")
        let fileInFirst = first.appendingPathComponent("notes.txt")
        try Data().write(to: fileInFirst)

        XCTAssertEqual(
            ExternalOpenDirectories.resolve([first, second, fileInFirst, second]),
            [first.standardizedFileURL.path, second.standardizedFileURL.path]
        )
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = rootURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
final class WorklaneStoreInitialWorkingDirectoryTests: XCTestCase {
    func test_default_worklane_starts_in_initial_working_directory() throws {
        let store = WorklaneStore(initialWorkingDirectory: "/tmp/zentty-open-target")

        let worklane = try XCTUnwrap(store.activeWorklane)
        let pane = try XCTUnwrap(worklane.paneStripState.panes.first)
        XCTAssertEqual(pane.sessionRequest.workingDirectory, "/tmp/zentty-open-target")
        XCTAssertEqual(worklane.auxiliaryStateByPaneID[pane.id]?.shellContext?.path, "/tmp/zentty-open-target")
    }

    func test_split_in_opened_window_inherits_initial_working_directory() throws {
        let store = WorklaneStore(initialWorkingDirectory: "/tmp/zentty-open-target")

        store.send(.splitAfterFocusedPane)

        let worklane = try XCTUnwrap(store.activeWorklane)
        let newPaneID = try XCTUnwrap(worklane.paneStripState.focusedPaneID)
        let newPane = try XCTUnwrap(worklane.paneStripState.panes.first(where: { $0.id == newPaneID }))
        XCTAssertEqual(newPane.sessionRequest.workingDirectory, "/tmp/zentty-open-target")
    }

    func test_without_initial_working_directory_default_worklane_starts_at_home() throws {
        let store = WorklaneStore()

        let pane = try XCTUnwrap(store.activeWorklane?.paneStripState.panes.first)
        XCTAssertEqual(pane.sessionRequest.workingDirectory, NSHomeDirectory())
    }

    func test_initial_working_directory_is_ignored_when_worklanes_are_supplied() throws {
        let worklaneID = WorklaneID("restored")
        let store = WorklaneStore(
            worklanes: [
                WorklaneState(
                    id: worklaneID,
                    title: nil,
                    paneStripState: PaneStripState(
                        columns: [
                            PaneColumnState(
                                id: PaneColumnID("column"),
                                panes: [
                                    PaneState(
                                        id: PaneID("restored-pane"),
                                        title: "restored",
                                        sessionRequest: TerminalSessionRequest(workingDirectory: "/tmp/restored")
                                    ),
                                ],
                                width: 600,
                                focusedPaneID: PaneID("restored-pane"),
                                lastFocusedPaneID: PaneID("restored-pane")
                            ),
                        ],
                        focusedColumnID: PaneColumnID("column")
                    )
                ),
            ],
            initialWorkingDirectory: "/tmp/zentty-open-target"
        )

        let pane = try XCTUnwrap(store.activeWorklane?.paneStripState.panes.first)
        XCTAssertEqual(pane.sessionRequest.workingDirectory, "/tmp/restored")
    }
}
