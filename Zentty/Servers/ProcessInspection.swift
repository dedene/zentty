import Darwin
import Foundation

protocol ProcessInspecting: Sendable {
    func listeningTCPSockets() -> [ListeningSocket]
    func parentPID(of pid: pid_t) -> pid_t?
    func workingDirectory(of pid: pid_t) -> String?
    func isProcessAlive(_ pid: pid_t) -> Bool
}

extension ProcessInspecting {
    /// Walks the parent chain from `pid` to determine whether it descends from
    /// `ancestorPID` (inclusive). Guards against cycles so a corrupt parent
    /// chain can't loop forever.
    func isProcess(_ pid: pid_t, descendantOf ancestorPID: pid_t) -> Bool {
        guard pid > 0, ancestorPID > 0 else {
            return false
        }
        if pid == ancestorPID {
            return true
        }

        var visited: Set<pid_t> = [pid]
        var currentPID = pid

        while let parentPID = parentPID(of: currentPID), parentPID > 0 {
            if parentPID == ancestorPID {
                return true
            }
            guard visited.insert(parentPID).inserted else {
                return false
            }
            currentPID = parentPID
        }

        return false
    }
}

struct ListeningSocket: Equatable, Sendable {
    let pid: pid_t
    let localHost: String
    let port: Int
}

struct PaneForegroundAgent: Equatable, Sendable {
    let tool: AgentTool
    let pid: Int32
    /// Includes launchers such as Codex's Node process, but not its children.
    let launchPIDs: Set<Int32>

    func owns(tool: AgentTool, pid: Int32?) -> Bool {
        self.tool == tool && (pid.map(launchPIDs.contains) ?? true)
    }
}

struct PaneForegroundAgentSnapshot: Equatable, Sendable {
    let agent: PaneForegroundAgent?
    let foregroundPIDs: Set<Int32>
}

struct PaneForegroundProcessInfo {
    let parentPID: Int32
    let processGroupID: Int32
    let foregroundProcessGroupID: Int32
    let terminalDevice: UInt32
    let name: String
    var executablePath: String? = nil

    var recognizedAgentTool: AgentTool? {
        if let tool = AgentTool.resolveKnown(named: name) { return tool }
        // Claude's native installer names the actual executable by version;
        // macOS reports that basename instead of the `claude` symlink.
        guard Self.isVersionName(name), let executablePath else { return nil }
        let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
        let directory = Array(executable.deletingLastPathComponent().pathComponents.suffix(4))
        guard executable.lastPathComponent == name,
              directory == [".local", "share", "claude", "versions"] else { return nil }
        return .claudeCode
    }

    static func isVersionName(_ name: String) -> Bool {
        name.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
    }
}

/// A fresh probe is shared by a sweep. Process reads are cached across panes;
/// a missing snapshot means inspection failed, not that the agent exited.
final class PaneForegroundAgentProbe {
    private let treePIDs: (Int32) -> [Int32]
    private let processInfo: (Int32) -> PaneForegroundProcessInfo?
    private var infoByPID: [Int32: PaneForegroundProcessInfo] = [:]
    private var missingPIDs: Set<Int32> = []

    init(
        treePIDs: @escaping (Int32) -> [Int32] = { DarwinProcessProbe().treePIDs(rootPID: $0) },
        processInfo: @escaping (Int32) -> PaneForegroundProcessInfo? = DarwinProcessInspector.foregroundInfo
    ) {
        self.treePIDs = treePIDs
        self.processInfo = processInfo
    }

    func scan(rootPID: Int32) -> PaneForegroundAgentSnapshot? {
        guard let root = info(rootPID), root.foregroundProcessGroupID > 0 else { return nil }
        let pids = treePIDs(rootPID)
        let listedPIDs = Set(pids)
        guard listedPIDs.contains(rootPID) else { return nil }
        // A process can exit or become unreadable between listing the tree
        // and inspecting it. Missing children cannot prove the job is empty.
        guard pids.allSatisfy({ pid in
            guard let process = info(pid) else { return false }
            return !PaneForegroundProcessInfo.isVersionName(process.name) || process.executablePath != nil
        }) else { return nil }
        let foregroundPIDs = Set(pids.filter { pid in
            guard let process = info(pid) else { return false }
            return process.terminalDevice == root.terminalDevice
                && process.processGroupID == root.foregroundProcessGroupID
        })
        var candidates: [PaneForegroundAgent] = []
        for pid in foregroundPIDs {
            guard let process = info(pid), let tool = process.recognizedAgentTool else { continue }
            var launchPIDs: Set<Int32> = [pid]
            var ancestor = process.parentPID
            var visited: Set<Int32> = [pid]
            var hasAgentAncestor = false
            var reachedRoot = pid == rootPID
            while !reachedRoot {
                guard ancestor > 0, listedPIDs.contains(ancestor),
                      visited.insert(ancestor).inserted, let parent = info(ancestor) else { return nil }
                if foregroundPIDs.contains(ancestor) {
                    launchPIDs.insert(ancestor)
                    if parent.recognizedAgentTool != nil { hasAgentAncestor = true }
                }
                reachedRoot = ancestor == rootPID
                ancestor = parent.parentPID
            }
            guard !hasAgentAncestor else { continue }
            candidates.append(PaneForegroundAgent(tool: tool, pid: pid, launchPIDs: launchPIDs))
        }
        // Two sibling agents in a pipeline have no single pane owner.
        guard candidates.count <= 1 else { return nil }
        return PaneForegroundAgentSnapshot(agent: candidates.first, foregroundPIDs: foregroundPIDs)
    }

    private func info(_ pid: Int32) -> PaneForegroundProcessInfo? {
        if let cached = infoByPID[pid] { return cached }
        if missingPIDs.contains(pid) { return nil }
        guard let value = processInfo(pid) else { missingPIDs.insert(pid); return nil }
        infoByPID[pid] = value
        return value
    }
}

struct DarwinProcessInspector: ProcessInspecting {
    static func foregroundInfo(_ pid: Int32) -> PaneForegroundProcessInfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size) else { return nil }
        var name = withUnsafeBytes(of: info.pbi_name) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        if name.isEmpty {
            name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        return PaneForegroundProcessInfo(
            parentPID: Int32(info.pbi_ppid), processGroupID: Int32(info.pbi_pgid),
            foregroundProcessGroupID: Int32(bitPattern: info.e_tpgid), terminalDevice: info.e_tdev,
            name: name,
            executablePath: PaneForegroundProcessInfo.isVersionName(name) ? executablePath(of: pid) : nil
        )
    }

    static func executablePath(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    func listeningTCPSockets() -> [ListeningSocket] {
        processIDs().flatMap(listeningTCPSockets(for:))
    }

    func parentPID(of pid: pid_t) -> pid_t? {
        guard pid > 0 else {
            return nil
        }

        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard result == Int32(size), info.pbi_ppid > 0 else {
            return nil
        }

        return pid_t(info.pbi_ppid)
    }

    func workingDirectory(of pid: pid_t) -> String? {
        ProcessCWDResolver.workingDirectory(for: pid)
    }

    func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else {
            return false
        }

        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Peer paths of every connected AF_UNIX socket `pid` holds. Lets callers
    /// tell which local daemon a process is talking to (e.g. an SSH agent).
    func unixSocketPeerPaths(of pid: pid_t) -> [String] {
        socketFDs(of: pid).compactMap { fd in
            var info = socket_fdinfo()
            let size = MemoryLayout<socket_fdinfo>.size
            let result = proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, Int32(size))
            guard result == Int32(size), info.psi.soi_kind == SOCKINFO_UN else {
                return nil
            }
            let path = Self.sunPath(info.psi.soi_proto.pri_un.unsi_caddr.ua_sun)
            return path.isEmpty ? nil : path
        }
    }

    private static func sunPath(_ address: sockaddr_un) -> String {
        withUnsafeBytes(of: address.sun_path) { rawBuffer in
            let bytes = rawBuffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private func socketFDs(of pid: pid_t) -> [Int32] {
        guard pid > 0 else {
            return []
        }

        let byteCount = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard byteCount > 0 else {
            return []
        }

        let capacity = Int(byteCount) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let usedByteCount = fds.withUnsafeMutableBufferPointer { buffer in
            proc_pidinfo(
                pid,
                PROC_PIDLISTFDS,
                0,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<proc_fdinfo>.stride)
            )
        }
        guard usedByteCount > 0 else {
            return []
        }

        return fds
            .prefix(Int(usedByteCount) / MemoryLayout<proc_fdinfo>.stride)
            .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }
            .map(\.proc_fd)
    }

    private func processIDs() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else {
            return []
        }

        let capacity = Int(byteCount) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: capacity)
        let usedByteCount = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.stride)
            )
        }

        guard usedByteCount > 0 else {
            return []
        }

        return pids
            .prefix(Int(usedByteCount) / MemoryLayout<pid_t>.stride)
            .filter { $0 > 0 }
    }

    private func listeningTCPSockets(for pid: pid_t) -> [ListeningSocket] {
        socketFDs(of: pid).compactMap { listeningTCPSocket(pid: pid, fd: $0) }
    }

    private func listeningTCPSocket(pid: pid_t, fd: Int32) -> ListeningSocket? {
        var info = socket_fdinfo()
        let size = MemoryLayout<socket_fdinfo>.size
        let result = proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, Int32(size))
        guard result == Int32(size) else {
            return nil
        }
        guard info.psi.soi_kind == SOCKINFO_TCP,
              info.psi.soi_family == AF_INET || info.psi.soi_family == AF_INET6,
              info.psi.soi_protocol == IPPROTO_TCP else {
            return nil
        }

        let tcpInfo = info.psi.soi_proto.pri_tcp
        guard tcpInfo.tcpsi_state == TSI_S_LISTEN else {
            return nil
        }

        let inInfo = tcpInfo.tcpsi_ini
        let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: inInfo.insi_lport)))
        guard port > 0 else {
            return nil
        }

        guard let host = localHost(from: inInfo, family: info.psi.soi_family) else {
            return nil
        }

        return ListeningSocket(pid: pid, localHost: host, port: port)
    }

    private func localHost(from inInfo: in_sockinfo, family: Int32) -> String? {
        switch family {
        case AF_INET:
            var address = inInfo.insi_laddr.ina_46.i46a_addr4
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            return inet_ntop(family, &address, &buffer, socklen_t(INET_ADDRSTRLEN)).map { _ in
                String(cString: buffer)
            }
        case AF_INET6:
            var address = inInfo.insi_laddr.ina_6
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            return inet_ntop(family, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)).map { _ in
                String(cString: buffer)
            }
        default:
            return nil
        }
    }
}
