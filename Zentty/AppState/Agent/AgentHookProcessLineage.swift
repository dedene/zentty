import Darwin

/// A hook's `ZENTTY_<TOOL>_PID` names the agent process the wrapper launched.
/// Hooks of a Claude background session run under the shared `claude daemon`
/// and inherit that variable from whichever pane started the daemon, so the
/// PID is only trusted when it is an ancestor of the hook process itself.
enum AgentHookProcessLineage {
    private static let maximumDepth = 64

    static func droppingInheritedPID(
        key: String,
        from environment: [String: String],
        isAncestor: (Int32) -> Bool = { isAncestor($0) }
    ) -> [String: String] {
        guard let rawPID = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(rawPID),
              !isAncestor(pid) else {
            return environment
        }
        var environment = environment
        environment.removeValue(forKey: key)
        return environment
    }

    static func isAncestor(
        _ pid: Int32,
        of process: Int32 = getpid(),
        parent: (Int32) -> Int32? = parentPID(of:)
    ) -> Bool {
        var current = process
        for _ in 0..<maximumDepth {
            guard let next = parent(current), next > 0 else { return false }
            if next == pid { return true }
            if next == 1 { return false }
            current = next
        }
        return false
    }

    static func parentPID(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return Int32(info.pbi_ppid)
    }
}
