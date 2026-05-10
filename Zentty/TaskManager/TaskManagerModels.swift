import Foundation

enum TaskManagerAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

enum TaskManagerNetworkState: Equatable, Sendable {
    case available(bytesPerSecond: UInt64)
    case unavailable(String)
}

struct TaskManagerPaneSource: Equatable, Sendable {
    let windowID: WindowID
    let windowTitle: String
    let worklaneID: WorklaneID
    let worklaneTitle: String
    let paneID: PaneID
    let paneTitle: String
    let statusText: String?
    let rootPID: Int32?
    let isRemote: Bool
    let currentWorkingDirectory: String?
}

struct TaskManagerProcessMetric: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32?
    let name: String
    let cpuPercent: Double
    let memoryBytes: UInt64
}

struct TaskManagerProcessTree: Equatable, Sendable {
    let rootPID: Int32
    let processes: [TaskManagerProcessMetric]
    let networkBytesPerSecond: UInt64?
}

struct TaskManagerProcessRow: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32?
    let name: String
    let cpuPercent: Double
    let memoryBytes: UInt64
}

struct TaskManagerPaneRow: Equatable, Sendable {
    let windowID: WindowID
    let windowTitle: String
    let worklaneID: WorklaneID
    let worklaneTitle: String
    let paneID: PaneID
    let paneTitle: String
    let statusText: String?
    let currentWorkingDirectory: String?
    let rootPID: Int32?
    let availability: TaskManagerAvailability
    let cpuPercent: Double?
    let peakCPUPercent: Double?
    let memoryBytes: UInt64?
    let peakMemoryBytes: UInt64?
    let networkState: TaskManagerNetworkState
    let hottestProcess: TaskManagerProcessRow?
    let processRows: [TaskManagerProcessRow]
    let isRemote: Bool
}

enum TaskManagerPaneRowBuilder {
    static func row(
        for pane: TaskManagerPaneSource,
        processTree: TaskManagerProcessTree?,
        previousRow: TaskManagerPaneRow? = nil
    ) -> TaskManagerPaneRow {
        guard pane.rootPID != nil else {
            return unavailableRow(
                for: pane,
                reason: pane.isRemote ? "Remote pane" : "Waiting for shell PID",
                previousRow: previousRow
            )
        }

        guard let processTree, !processTree.processes.isEmpty else {
            return unavailableRow(for: pane, reason: "Metrics unavailable", previousRow: previousRow)
        }

        let processRows = processTree.processes
            .map {
                TaskManagerProcessRow(
                    pid: $0.pid,
                    parentPID: $0.parentPID,
                    name: $0.name,
                    cpuPercent: $0.cpuPercent,
                    memoryBytes: $0.memoryBytes
                )
            }
            .sorted { lhs, rhs in
                if lhs.cpuPercent != rhs.cpuPercent {
                    return lhs.cpuPercent > rhs.cpuPercent
                }
                if lhs.memoryBytes != rhs.memoryBytes {
                    return lhs.memoryBytes > rhs.memoryBytes
                }
                return lhs.pid < rhs.pid
            }
        let cpuPercent = processRows.reduce(0) { $0 + $1.cpuPercent }
        let memoryBytes = processRows.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        let hottestProcess = processRows.first

        return TaskManagerPaneRow(
            windowID: pane.windowID,
            windowTitle: pane.windowTitle,
            worklaneID: pane.worklaneID,
            worklaneTitle: pane.worklaneTitle,
            paneID: pane.paneID,
            paneTitle: pane.paneTitle,
            statusText: pane.statusText,
            currentWorkingDirectory: pane.currentWorkingDirectory,
            rootPID: pane.rootPID,
            availability: .available,
            cpuPercent: cpuPercent,
            peakCPUPercent: max(cpuPercent, previousRow?.peakCPUPercent ?? 0),
            memoryBytes: memoryBytes,
            peakMemoryBytes: max(memoryBytes, previousRow?.peakMemoryBytes ?? 0),
            networkState: processTree.networkBytesPerSecond.map(TaskManagerNetworkState.available(bytesPerSecond:))
                ?? .unavailable("Unavailable"),
            hottestProcess: hottestProcess,
            processRows: processRows,
            isRemote: pane.isRemote
        )
    }

    private static func unavailableRow(
        for pane: TaskManagerPaneSource,
        reason: String,
        previousRow: TaskManagerPaneRow?
    ) -> TaskManagerPaneRow {
        TaskManagerPaneRow(
            windowID: pane.windowID,
            windowTitle: pane.windowTitle,
            worklaneID: pane.worklaneID,
            worklaneTitle: pane.worklaneTitle,
            paneID: pane.paneID,
            paneTitle: pane.paneTitle,
            statusText: pane.statusText,
            currentWorkingDirectory: pane.currentWorkingDirectory,
            rootPID: pane.rootPID,
            availability: .unavailable(reason),
            cpuPercent: nil,
            peakCPUPercent: previousRow?.peakCPUPercent,
            memoryBytes: nil,
            peakMemoryBytes: previousRow?.peakMemoryBytes,
            networkState: .unavailable("Unavailable"),
            hottestProcess: nil,
            processRows: [],
            isRemote: pane.isRemote
        )
    }
}

enum TaskManagerRowFilter {
    static func filter(_ rows: [TaskManagerPaneRow], query: String) -> [TaskManagerPaneRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return rows
        }

        return rows.filter { row in
            searchableText(for: row).contains(needle)
        }
    }

    private static func searchableText(for row: TaskManagerPaneRow) -> String {
        var values = [
            row.windowTitle,
            row.worklaneTitle,
            row.paneTitle,
            row.statusText,
            row.currentWorkingDirectory,
            row.rootPID.map(String.init),
            row.hottestProcess?.name,
            row.hottestProcess.map { String($0.pid) },
        ].compactMap { $0 }

        values.append(contentsOf: row.processRows.flatMap { process in
            [process.name, String(process.pid), process.parentPID.map(String.init)].compactMap { $0 }
        })

        return values.joined(separator: " ").lowercased()
    }
}

enum TaskManagerStableSorter {
    private static let cpuHysteresisPercent = 1.0

    static func sort(_ rows: [TaskManagerPaneRow], previousOrder: [PaneID]) -> [TaskManagerPaneRow] {
        let previousIndex = Dictionary(uniqueKeysWithValues: previousOrder.enumerated().map { ($0.element, $0.offset) })

        return rows.sorted { lhs, rhs in
            let lhsCPU = lhs.cpuPercent ?? -1
            let rhsCPU = rhs.cpuPercent ?? -1
            if abs(lhsCPU - rhsCPU) <= cpuHysteresisPercent,
               let lhsPrevious = previousIndex[lhs.paneID],
               let rhsPrevious = previousIndex[rhs.paneID],
               lhsPrevious != rhsPrevious {
                return lhsPrevious < rhsPrevious
            }
            if lhsCPU != rhsCPU {
                return lhsCPU > rhsCPU
            }
            let lhsMemory = lhs.memoryBytes ?? 0
            let rhsMemory = rhs.memoryBytes ?? 0
            if lhsMemory != rhsMemory {
                return lhsMemory > rhsMemory
            }
            return lhs.paneTitle.localizedStandardCompare(rhs.paneTitle) == .orderedAscending
        }
    }
}

enum TaskManagerMetricFormatter {
    static func cpu(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.1f%%", value)
    }

    static func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func network(_ state: TaskManagerNetworkState) -> String {
        switch state {
        case .available(let bytesPerSecond):
            return "\(ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file))/s"
        case .unavailable:
            return "-"
        }
    }
}
