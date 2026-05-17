import Darwin
import Foundation

protocol ProcessInspecting: Sendable {
    func listeningTCPSockets() -> [ListeningSocket]
    func parentPID(of pid: pid_t) -> pid_t?
    func workingDirectory(of pid: pid_t) -> String?
    func isProcessAlive(_ pid: pid_t) -> Bool
}

struct ListeningSocket: Equatable, Sendable {
    let pid: pid_t
    let localHost: String
    let port: Int
}

struct DarwinProcessInspector: ProcessInspecting {
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
            .compactMap { fd -> ListeningSocket? in
                guard fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else {
                    return nil
                }

                return listeningTCPSocket(pid: pid, fd: fd.proc_fd)
            }
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
