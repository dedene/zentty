import Darwin
import XCTest
@testable import Zentty

final class TaskManagerProcessSamplerTests: XCTestCase {
    /// Regression: a single shared sampler used to prune its history down to the
    /// last tree it sampled. With 2+ panes that wiped every sibling's previous
    /// sample on each tick, so every row reported 0.0% CPU forever.
    func test_sibling_trees_keep_cpu_history_across_ticks() {
        let probe = FakeProbe()
        let sampler = TaskManagerProcessSampler(probe: probe)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let t1 = t0.addingTimeInterval(1)

        probe.trees = [100: [100], 200: [200]]
        probe.cpuTime = [100: 0, 200: 0]
        _ = sampler.sample(rootPIDs: [100, 200], now: t0)

        // Each process burned a full second of CPU over the 1s interval → 100%.
        probe.cpuTime = [100: 1_000_000_000, 200: 1_000_000_000]
        let trees = sampler.sample(rootPIDs: [100, 200], now: t1)

        XCTAssertEqual(trees[100]?.processes.first?.cpuPercent ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(trees[200]?.processes.first?.cpuPercent ?? -1, 100, accuracy: 0.001)
    }

    func test_partial_cpu_usage_is_proportional() {
        let probe = FakeProbe()
        let sampler = TaskManagerProcessSampler(probe: probe)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)

        probe.trees = [100: [100]]
        probe.cpuTime = [100: 0]
        _ = sampler.sample(rootPIDs: [100], now: t0)

        // 0.5s of CPU over a 2s interval → 25%.
        probe.cpuTime = [100: 500_000_000]
        let trees = sampler.sample(rootPIDs: [100], now: t0.addingTimeInterval(2))

        XCTAssertEqual(trees[100]?.processes.first?.cpuPercent ?? -1, 25, accuracy: 0.001)
    }

    func test_dead_pids_are_pruned_from_history() {
        let probe = FakeProbe()
        let sampler = TaskManagerProcessSampler(probe: probe)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)

        probe.trees = [100: [100, 101]]
        probe.cpuTime = [100: 0, 101: 0]
        _ = sampler.sample(rootPIDs: [100], now: t0)

        // 101 exits; the surviving process still reports a correct delta.
        probe.trees = [100: [100]]
        probe.cpuTime = [100: 250_000_000]
        let trees = sampler.sample(rootPIDs: [100], now: t0.addingTimeInterval(1))

        XCTAssertEqual(trees[100]?.processes.map(\.pid), [100])
        XCTAssertEqual(trees[100]?.processes.first?.cpuPercent ?? -1, 25, accuracy: 0.001)
    }

    func test_first_sample_reports_zero_without_history() {
        let probe = FakeProbe()
        let sampler = TaskManagerProcessSampler(probe: probe)
        probe.trees = [100: [100]]
        probe.cpuTime = [100: 999_000_000]

        let trees = sampler.sample(rootPIDs: [100], now: Date())

        XCTAssertEqual(trees[100]?.processes.first?.cpuPercent, 0)
    }

    // The single-tree convenience is the contract the workspace-template capture
    // path relies on: it wants the process topology for one root, not CPU deltas.
    func test_single_tree_convenience_returns_matching_tree() {
        let probe = FakeProbe()
        let sampler = TaskManagerProcessSampler(probe: probe)
        probe.trees = [100: [100, 101]]
        probe.cpuTime = [100: 0, 101: 0]

        let tree = sampler.sample(rootPID: 100)

        XCTAssertEqual(tree?.rootPID, 100)
        XCTAssertEqual(tree?.processes.map(\.pid).sorted(), [100, 101])
    }

    func test_single_tree_convenience_rejects_nonpositive_root() {
        let sampler = TaskManagerProcessSampler(probe: FakeProbe())

        XCTAssertNil(sampler.sample(rootPID: 0))
        XCTAssertNil(sampler.sample(rootPID: -1))
    }

    // Regression: PROC_PIDTASKINFO CPU times are mach ticks, not nanoseconds.
    // Without the timebase conversion, Apple Silicon under-reports CPU by ~40x
    // (a fully-busy core showed ~2.4% instead of ~100%).
    func test_mach_time_converts_to_nanoseconds_on_apple_silicon() {
        // Apple Silicon timebase: 125/3 ≈ 41.67 ns per tick.
        let timebase = mach_timebase_info_data_t(numer: 125, denom: 3)

        XCTAssertEqual(DarwinProcessProbe.nanoseconds(fromMachTime: 3, timebase: timebase), 125)
        XCTAssertEqual(DarwinProcessProbe.nanoseconds(fromMachTime: 24, timebase: timebase), 1_000)

        // One core fully busy for 1s reads ~24M ticks; must resolve to ~1e9 ns.
        let oneSecondOfTicks: UInt64 = 24_000_000
        let ns = DarwinProcessProbe.nanoseconds(fromMachTime: oneSecondOfTicks, timebase: timebase)
        XCTAssertEqual(Double(ns), 1_000_000_000, accuracy: 1_000)
    }

    func test_mach_time_passthrough_on_intel_timebase() {
        // Intel timebase is 1/1, so ticks already equal nanoseconds.
        let timebase = mach_timebase_info_data_t(numer: 1, denom: 1)

        XCTAssertEqual(DarwinProcessProbe.nanoseconds(fromMachTime: 123_456, timebase: timebase), 123_456)
    }

    func test_mach_time_guards_degenerate_timebase() {
        let zeroDenom = mach_timebase_info_data_t(numer: 125, denom: 0)
        XCTAssertEqual(DarwinProcessProbe.nanoseconds(fromMachTime: 99, timebase: zeroDenom), 99)
    }

    private final class FakeProbe: TaskManagerProcessProbing {
        var trees: [Int32: [Int32]] = [:]
        var cpuTime: [Int32: UInt64] = [:]

        func treePIDs(rootPID: Int32) -> [Int32] {
            trees[rootPID] ?? []
        }

        func sample(pid: Int32) -> TaskManagerProbeSample? {
            guard let cpu = cpuTime[pid] else {
                return nil
            }
            return TaskManagerProbeSample(
                cpuTimeNanoseconds: cpu,
                parentPID: nil,
                name: "process-\(pid)",
                memoryBytes: 1_000_000
            )
        }
    }
}
