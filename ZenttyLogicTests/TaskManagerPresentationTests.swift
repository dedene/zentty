import XCTest
@testable import Zentty

final class TaskManagerPresentationTests: XCTestCase {
    func test_pane_row_aggregates_processes_and_picks_hottest_child() {
        let pane = TaskManagerPaneSource(
            windowID: WindowID("window-main"),
            windowTitle: "Main Window",
            worklaneID: WorklaneID("worklane-api"),
            worklaneTitle: "API",
            paneID: PaneID("pane-server"),
            paneTitle: "Server",
            statusText: "Running tests",
            rootPID: 100,
            isRemote: false,
            currentWorkingDirectory: "/Users/peter/project"
        )
        let processTree = TaskManagerProcessTree(
            rootPID: 100,
            processes: [
                TaskManagerProcessMetric(pid: 100, parentPID: nil, name: "zsh", cpuPercent: 1, memoryBytes: 20_000_000),
                TaskManagerProcessMetric(pid: 101, parentPID: 100, name: "xcodebuild", cpuPercent: 175, memoryBytes: 700_000_000),
                TaskManagerProcessMetric(pid: 102, parentPID: 101, name: "swift-frontend", cpuPercent: 40, memoryBytes: 200_000_000),
            ],
            networkBytesPerSecond: nil
        )

        let row = TaskManagerPaneRowBuilder.row(for: pane, processTree: processTree)

        XCTAssertEqual(row.cpuPercent, 216)
        XCTAssertEqual(row.memoryBytes, 920_000_000)
        XCTAssertEqual(row.hottestProcess?.name, "xcodebuild")
        XCTAssertEqual(row.processRows.map(\.pid), [101, 102, 100])
        XCTAssertEqual(row.networkState, .unavailable("Unavailable"))
    }

    func test_pane_without_root_pid_stays_visible_with_reason() {
        let pane = TaskManagerPaneSource(
            windowID: WindowID("window-main"),
            windowTitle: "Main Window",
            worklaneID: WorklaneID("worklane-api"),
            worklaneTitle: "API",
            paneID: PaneID("pane-server"),
            paneTitle: "Server",
            statusText: nil,
            rootPID: nil,
            isRemote: false,
            currentWorkingDirectory: "/Users/peter/project"
        )

        let row = TaskManagerPaneRowBuilder.row(for: pane, processTree: nil)

        XCTAssertEqual(row.availability, .unavailable("Waiting for shell PID"))
        XCTAssertNil(row.cpuPercent)
        XCTAssertNil(row.memoryBytes)
    }

    func test_filter_matches_worklane_process_cwd_and_pid() {
        let rows = [
            makeRow(paneTitle: "Server", worklaneTitle: "API", cwd: "/repo/api", process: "node", pid: 100, cpu: 10),
            makeRow(paneTitle: "Shell", worklaneTitle: "Docs", cwd: "/repo/docs", process: "vim", pid: 200, cpu: 1),
        ]

        XCTAssertEqual(TaskManagerRowFilter.filter(rows, query: "api").map(\.paneID), [PaneID("Server")])
        XCTAssertEqual(TaskManagerRowFilter.filter(rows, query: "vim").map(\.paneID), [PaneID("Shell")])
        XCTAssertEqual(TaskManagerRowFilter.filter(rows, query: "200").map(\.paneID), [PaneID("Shell")])
        XCTAssertEqual(TaskManagerRowFilter.filter(rows, query: "repo/docs").map(\.paneID), [PaneID("Shell")])
    }

    func test_stable_hot_first_sort_avoids_tiny_reorders() {
        let previousOrder = [PaneID("A"), PaneID("B")]
        let rows = [
            makeRow(paneTitle: "B", worklaneTitle: "Main", cwd: nil, process: "node", pid: 2, cpu: 50.1),
            makeRow(paneTitle: "A", worklaneTitle: "Main", cwd: nil, process: "swift", pid: 1, cpu: 50.0),
        ]

        let sorted = TaskManagerStableSorter.sort(rows, previousOrder: previousOrder)

        XCTAssertEqual(sorted.map(\.paneID), [PaneID("A"), PaneID("B")])
    }

    private func makeRow(
        paneTitle: String,
        worklaneTitle: String,
        cwd: String?,
        process: String,
        pid: Int32,
        cpu: Double
    ) -> TaskManagerPaneRow {
        TaskManagerPaneRow(
            windowID: WindowID("window"),
            windowTitle: "Window",
            worklaneID: WorklaneID(worklaneTitle),
            worklaneTitle: worklaneTitle,
            paneID: PaneID(paneTitle),
            paneTitle: paneTitle,
            statusText: nil,
            currentWorkingDirectory: cwd,
            rootPID: pid,
            availability: .available,
            cpuPercent: cpu,
            peakCPUPercent: cpu,
            memoryBytes: 100,
            peakMemoryBytes: 100,
            networkState: .unavailable("Unavailable"),
            hottestProcess: TaskManagerProcessRow(pid: pid, parentPID: nil, name: process, cpuPercent: cpu, memoryBytes: 100),
            processRows: [
                TaskManagerProcessRow(pid: pid, parentPID: nil, name: process, cpuPercent: cpu, memoryBytes: 100)
            ],
            isRemote: false
        )
    }
}
