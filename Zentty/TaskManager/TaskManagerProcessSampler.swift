import Darwin
import Foundation

final class TaskManagerProcessSampler {
    private struct Sample: Sendable {
        let cpuTimeNanoseconds: UInt64
        let sampledAt: Date
    }

    private var previousSamplesByPID: [Int32: Sample] = [:]

    func sample(rootPID: Int32, now: Date = Date()) -> TaskManagerProcessTree? {
        guard rootPID > 0 else {
            return nil
        }

        let pids = processTreePIDs(rootPID: rootPID)
        guard !pids.isEmpty else {
            previousSamplesByPID[rootPID] = nil
            return nil
        }

        let metrics = pids.compactMap { pid -> TaskManagerProcessMetric? in
            guard let info = taskInfo(pid: pid) else {
                return nil
            }
            let totalCPUTime = UInt64(info.pti_total_user) + UInt64(info.pti_total_system)
            let previous = previousSamplesByPID[pid]
            previousSamplesByPID[pid] = Sample(cpuTimeNanoseconds: totalCPUTime, sampledAt: now)

            let elapsed = previous.map { now.timeIntervalSince($0.sampledAt) } ?? 0
            let cpuPercent: Double
            if let previous, elapsed > 0 {
                let delta = totalCPUTime > previous.cpuTimeNanoseconds
                    ? totalCPUTime - previous.cpuTimeNanoseconds
                    : 0
                cpuPercent = Double(delta) / (elapsed * 1_000_000_000) * 100
            } else {
                cpuPercent = 0
            }

            return TaskManagerProcessMetric(
                pid: pid,
                parentPID: parentPID(pid: pid),
                name: processName(pid: pid),
                cpuPercent: cpuPercent,
                memoryBytes: UInt64(max(info.pti_resident_size, 0))
            )
        }

        let livePIDSet = Set(pids)
        previousSamplesByPID = previousSamplesByPID.filter { livePIDSet.contains($0.key) }

        return TaskManagerProcessTree(
            rootPID: rootPID,
            processes: metrics,
            networkBytesPerSecond: nil
        )
    }

    private func processTreePIDs(rootPID: Int32) -> [Int32] {
        guard processExists(rootPID) else {
            return []
        }

        var result: [Int32] = []
        var queue = [rootPID]
        var visited = Set<Int32>()

        while let pid = queue.first {
            queue.removeFirst()
            guard visited.insert(pid).inserted else {
                continue
            }

            result.append(pid)
            queue.append(contentsOf: childPIDs(parentPID: pid))
        }

        return result
    }

    private func childPIDs(parentPID: Int32) -> [Int32] {
        let capacity = 4096
        var pids = Array(repeating: pid_t(0), count: capacity)
        let bufferBytes = Int32(capacity * MemoryLayout<pid_t>.stride)
        let result = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listchildpids(parentPID, buffer.baseAddress, bufferBytes)
        }
        guard result > 0 else {
            return []
        }

        let rawCount = Int(result)
        let writtenCount = rawCount <= capacity
            ? rawCount
            : rawCount / MemoryLayout<pid_t>.stride
        let count = Swift.min(writtenCount, pids.count)
        return (0..<count).map { Int32(pids[$0]) }.filter { $0 > 0 }
    }

    private func taskInfo(pid: Int32) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.stride
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size))
        guard result == Int32(size) else {
            return nil
        }
        return info
    }

    private func parentPID(pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard result == Int32(size), info.pbi_ppid > 0 else {
            return nil
        }
        return Int32(info.pbi_ppid)
    }

    private func processName(pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN))
        let result = proc_name(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else {
            return "pid \(pid)"
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else {
            return false
        }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }
}
