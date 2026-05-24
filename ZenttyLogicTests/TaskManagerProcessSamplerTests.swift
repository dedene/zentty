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
