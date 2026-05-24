import Darwin
import Foundation

/// One reading of a single process: cumulative CPU time plus the instantaneous
/// fields the Task Manager displays directly.
struct TaskManagerProbeSample {
    let cpuTimeNanoseconds: UInt64
    let parentPID: Int32?
    let name: String
    let memoryBytes: UInt64
}

/// Abstracts the OS-level process probing so the sampler's delta/prune logic can
/// be exercised deterministically in tests without real subprocesses.
protocol TaskManagerProcessProbing {
    func treePIDs(rootPID: Int32) -> [Int32]
    func sample(pid: Int32) -> TaskManagerProbeSample?
}

final class TaskManagerProcessSampler {
    private struct Sample {
        let cpuTimeNanoseconds: UInt64
        let sampledAt: Date
    }

    private let probe: TaskManagerProcessProbing
    private var previousSamplesByPID: [Int32: Sample] = [:]

    init(probe: TaskManagerProcessProbing = DarwinProcessProbe()) {
        self.probe = probe
    }

    /// Samples every supplied root PID in a single pass and prunes history against
    /// the union of all live PIDs.
    ///
    /// This is the API the Task Manager refresh loop must use: pruning per tree in
    /// isolation would wipe every *other* tree's previous sample on the same tick,
    /// forcing all CPU deltas to zero whenever more than one pane is shown.
    func sample(rootPIDs: [Int32], now: Date = Date()) -> [Int32: TaskManagerProcessTree] {
        var trees: [Int32: TaskManagerProcessTree] = [:]
        var nextSamples: [Int32: Sample] = [:]

        for rootPID in rootPIDs where rootPID > 0 {
            let pids = probe.treePIDs(rootPID: rootPID)
            guard !pids.isEmpty else {
                continue
            }

            let metrics = pids.compactMap { pid -> TaskManagerProcessMetric? in
                guard let reading = probe.sample(pid: pid) else {
                    return nil
                }
                let previous = previousSamplesByPID[pid]
                nextSamples[pid] = Sample(cpuTimeNanoseconds: reading.cpuTimeNanoseconds, sampledAt: now)
                return TaskManagerProcessMetric(
                    pid: pid,
                    parentPID: reading.parentPID,
                    name: reading.name,
                    cpuPercent: Self.cpuPercent(current: reading.cpuTimeNanoseconds, previous: previous, now: now),
                    memoryBytes: reading.memoryBytes
                )
            }

            trees[rootPID] = TaskManagerProcessTree(
                rootPID: rootPID,
                processes: metrics,
                networkBytesPerSecond: nil
            )
        }

        // Drop history for PIDs that are no longer part of any sampled tree. Done
        // once per pass over the union, so sibling trees never erase each other.
        previousSamplesByPID = nextSamples
        return trees
    }

    /// Single-tree convenience for one-shot callers (e.g. workspace template
    /// capture) that only need the process topology, not CPU deltas.
    func sample(rootPID: Int32, now: Date = Date()) -> TaskManagerProcessTree? {
        guard rootPID > 0 else {
            return nil
        }
        return sample(rootPIDs: [rootPID], now: now)[rootPID]
    }

    private static func cpuPercent(current: UInt64, previous: Sample?, now: Date) -> Double {
        guard let previous else {
            return 0
        }
        let elapsed = now.timeIntervalSince(previous.sampledAt)
        guard elapsed > 0, current > previous.cpuTimeNanoseconds else {
            return 0
        }
        let delta = current - previous.cpuTimeNanoseconds
        return Double(delta) / (elapsed * 1_000_000_000) * 100
    }
}

/// Real macOS process probing via `proc_*` syscalls.
struct DarwinProcessProbe: TaskManagerProcessProbing {
    /// Process mach timebase; constant for the process lifetime.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    func treePIDs(rootPID: Int32) -> [Int32] {
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

    func sample(pid: Int32) -> TaskManagerProbeSample? {
        guard let info = taskInfo(pid: pid) else {
            return nil
        }
        let cpuTicks = UInt64(info.pti_total_user) + UInt64(info.pti_total_system)
        return TaskManagerProbeSample(
            cpuTimeNanoseconds: Self.nanoseconds(fromMachTime: cpuTicks, timebase: Self.timebase),
            parentPID: parentPID(pid: pid),
            name: processName(pid: pid),
            memoryBytes: UInt64(max(info.pti_resident_size, 0))
        )
    }

    /// `proc_pidinfo(PROC_PIDTASKINFO)` reports CPU time in mach absolute-time
    /// units, not nanoseconds. On Intel the timebase is 1/1 so they coincide; on
    /// Apple Silicon a tick is ~41.67ns (timebase 125/3), so the raw value must be
    /// scaled or CPU% reads ~40x too low.
    static func nanoseconds(fromMachTime ticks: UInt64, timebase: mach_timebase_info_data_t) -> UInt64 {
        guard timebase.numer != 0, timebase.denom != 0, timebase.numer != timebase.denom else {
            return ticks
        }
        let scaled = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer))
        guard !scaled.overflow else {
            // Unreachable for realistic CPU times; fall back to lossy float math.
            return UInt64((Double(ticks) * Double(timebase.numer) / Double(timebase.denom)).rounded())
        }
        return scaled.partialValue / UInt64(timebase.denom)
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
