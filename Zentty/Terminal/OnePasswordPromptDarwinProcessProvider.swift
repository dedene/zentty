import Darwin
import Foundation

/// Real `proc_*` backed provider for `OnePasswordPromptAttributor`.
struct OnePasswordPromptDarwinProcessProvider: OnePasswordPromptProcessProviding {
    private let treeProvider = DarwinPaneSSHProcessTreeProvider()
    private let argvProvider = DarwinPaneSSHProcessArgvProvider()

    func treePIDs(rootPID: Int32) -> [Int32] {
        treeProvider.treePIDs(rootPID: rootPID)
    }

    func processName(pid: Int32) -> String? {
        treeProvider.processName(pid: pid)
    }

    func argv(pid: Int32) -> [String]? {
        argvProvider.argv(pid: pid)
    }

    func startTime(pid: Int32) -> TimeInterval? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard result == Int32(size) else {
            return nil
        }
        return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
    }

    func unixSocketPeerPaths(pid: Int32) -> [String] {
        DarwinProcessInspector().unixSocketPeerPaths(of: pid)
    }
}
