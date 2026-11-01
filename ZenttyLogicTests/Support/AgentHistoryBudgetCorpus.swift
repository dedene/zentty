import Darwin
import Foundation
@testable import Zentty

/// A synthetic Claude Code root on disk for the backfill budgets of spec §10
/// (`AgentHistoryBudgetTests`). The default shape stands in for a large real corpus:
///
/// - ~2 GB of `projects/<encoded cwd>/<uuid>.jsonl` transcripts over 40 projects, 2,000 sessions
///   with log-normal sizes, and six 120 MB sessions (one of them among the newest 50, the way a
///   long-running active session is).
/// - Bytes are dominated by tool results, as in real transcripts: sniffed and skipped by the
///   adapter, while prompts (~200 chars) and replies (~900 chars) are indexed. A few lines are
///   1–12 MB, so lines past `JSONLTailReader.defaultMaxLineBytes` are discarded mid-file.
/// - File mtimes go newest first by rank, two years back; the rank-0 session is the newest.
///
/// Generation streams through a 4 MB buffer, so it adds no memory of its own to the process the
/// budgets measure. Lines are assembled from bytes rather than `JSONSerialization` (2 GB of
/// fixtures would take minutes); every string is plain ASCII that needs no JSON escaping.
/// Deterministic for a given configuration.
struct AgentHistoryBudgetCorpus {
    struct Configuration: Sendable {
        var seed: UInt64 = 0x00B0_D6E7_5EED
        var sessionCount = 2_000
        var projectCount = 40
        var totalBytes: Int64 = 2 << 30
        /// Newest-first ranks of the large sessions.
        var largeSessionRanks: Set<Int> = [3, 300, 700, 1_100, 1_500, 1_900]
        var largeSessionBytes: Int64 = 120 << 20
        var spanDays = 730

        /// ~2 GB, or `ZENTTY_HISTORY_BENCH_CORPUS_MB` (forwarded from
        /// `TEST_RUNNER_ZENTTY_HISTORY_BENCH_CORPUS_MB`) when set.
        static var benchmark: Configuration {
            var configuration = Configuration()
            if let raw = ProcessInfo.processInfo.environment["ZENTTY_HISTORY_BENCH_CORPUS_MB"],
               let megabytes = Int64(raw), megabytes > 0 {
                configuration.totalBytes = megabytes << 20
            }
            return configuration
        }

        /// A few MB over 150 sessions: enough work for a launch to backfill, quickly.
        static let small = Configuration(
            sessionCount: 150, projectCount: 8, totalBytes: 12 << 20, largeSessionRanks: [], largeSessionBytes: 0
        )
    }

    struct Session: Sendable {
        let rank: Int
        let nativeID: String
        let path: String
        let bytes: Int64
    }

    struct Summary: Sendable {
        /// Newest first (rank order).
        let sessions: [Session]
        let totalBytes: Int64
        /// Prompts and replies: the lines that become messages.
        let textMessages: Int
        /// Tool-result lines of 1 MB or more.
        let longLines: Int
        let seconds: Double
    }

    let configuration: Configuration

    init(_ configuration: Configuration) {
        self.configuration = configuration
    }

    /// Writes the corpus into `claudeRoot` (created; `projects/` inside it).
    func generate(into claudeRoot: URL) throws -> Summary {
        let started = DispatchTime.now().uptimeNanoseconds
        let config = configuration
        var rng = HistorySplitMix64(seed: config.seed)
        let pools = Pools(rng: &rng)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000) - 3_600_000
        let spacingMs = Int64(config.spanDays) * 86_400_000 / Int64(max(config.sessionCount, 1))

        let projects = (0..<config.projectCount).map { index in
            "/Users/bench/dev/repo-\(String(format: "%02d", index))"
        }
        for cwd in projects {
            try FileManager.default.createDirectory(
                at: Self.projectURL(claudeRoot, cwd: cwd), withIntermediateDirectories: true
            )
        }

        let sizes = sessionSizes(&rng)
        var sessions: [Session] = []
        sessions.reserveCapacity(config.sessionCount)
        var totals = (bytes: Int64(0), messages: 0, longLines: 0)
        for rank in 0..<config.sessionCount {
            var sessionRNG = HistorySplitMix64(seed: config.seed &+ UInt64(rank + 1) &* 0x9E37_79B9_7F4A_7C15)
            let nativeID = Self.uuid(&sessionRNG)
            let cwd = projects[sessionRNG.below(projects.count)]
            let url = Self.projectURL(claudeRoot, cwd: cwd).appendingPathComponent("\(nativeID).jsonl")
            let endMs = nowMs - Int64(rank) * spacingMs
            let written = try writeSession(
                SessionSpec(nativeID: nativeID, cwd: cwd, targetBytes: sizes[rank], endMs: endMs,
                            isLarge: config.largeSessionRanks.contains(rank)),
                to: url, pools: pools, rng: &sessionRNG
            )
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(endMs) / 1_000)], ofItemAtPath: url.path
            )
            sessions.append(Session(rank: rank, nativeID: nativeID, path: url.path, bytes: written.bytes))
            totals.bytes += written.bytes
            totals.messages += written.messages
            totals.longLines += written.longLines
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        return Summary(sessions: sessions, totalBytes: totals.bytes, textMessages: totals.messages,
                       longLines: totals.longLines, seconds: seconds)
    }

    // MARK: - Shape

    /// Target bytes per rank: the large sessions get `largeSessionBytes`, the rest share what is
    /// left by log-normal weight, clamped to 16 KB–40 MB.
    private func sessionSizes(_ rng: inout HistorySplitMix64) -> [Int64] {
        let config = configuration
        let large = config.largeSessionRanks.filter { $0 < config.sessionCount }
        let remaining = max(config.totalBytes - Int64(large.count) * config.largeSessionBytes, 0)
        let weights = (0..<config.sessionCount).map { _ in rng.logNormal(median: 1, sigma: 1.2) }
        let smallWeight = weights.enumerated().filter { !large.contains($0.offset) }.map(\.element).reduce(0, +)
        return weights.enumerated().map { rank, weight in
            if large.contains(rank) {
                return config.largeSessionBytes
            }
            let share = Double(remaining) * weight / max(smallWeight, .leastNonzeroMagnitude)
            return min(max(Int64(share), 16 << 10), 40 << 20)
        }
    }

    private struct SessionSpec {
        let nativeID: String
        let cwd: String
        let targetBytes: Int64
        let endMs: Int64
        let isLarge: Bool
    }

    /// Turns of prompt → reply with a Bash call → tool result until `targetBytes`. Timestamps run
    /// up to `endMs`, a few seconds apart.
    private func writeSession(
        _ spec: SessionSpec,
        to url: URL,
        pools: Pools,
        rng: inout HistorySplitMix64
    ) throws -> (bytes: Int64, messages: Int, longLines: Int) {
        let writer = try BufferedWriter(url: url)
        let head = "{\"cwd\":\"\(spec.cwd)\",\"gitBranch\":\"main\",\"isSidechain\":false,\"message\":"
        let tail = ",\"sessionId\":\"\(spec.nativeID)\",\"timestamp\":\""
        var atMs = spec.endMs - 6 * 3_600_000
        var messages = 0
        var longLines = 0

        writer.append("{\"aiTitle\":\"")
        writer.append(pools.text, offset: rng.below(pools.text.count - 80), count: 24 + rng.below(40))
        writer.append("\",\"sessionId\":\"\(spec.nativeID)\",\"type\":\"ai-title\"}\n")

        while writer.written < spec.targetBytes {
            let toolID = "toolu_" + Self.hex(rng.next())
            let isCommit = rng.chance(0.05)

            writer.append(head + "{\"content\":\"")
            writer.append(pools.text, offset: rng.below(pools.text.count / 2),
                          count: Self.clamp(rng.logNormal(median: 200, sigma: 0.6), 20, 4_000))
            writer.append("\",\"role\":\"user\"}" + tail + Self.timestamp(atMs)
                          + "\",\"type\":\"user\",\"userType\":\"external\",\"uuid\":\"\(Self.uuid(&rng))\"}\n")
            atMs = min(atMs + 1_000 + Int64(rng.below(4_000)), spec.endMs)

            let command = isCommit
                ? "git commit -m 'bench change \(rng.below(10_000))'"
                : rng.pick(Self.commands) + " " + String(rng.below(1_000))
            writer.append(head + "{\"content\":[{\"text\":\"")
            writer.append(pools.text, offset: rng.below(pools.text.count / 2),
                          count: Self.clamp(rng.logNormal(median: 900, sigma: 0.7), 40, 16_000))
            writer.append("\",\"type\":\"text\"},{\"id\":\"\(toolID)\",\"input\":{\"command\":\"\(command)\"},"
                          + "\"name\":\"Bash\",\"type\":\"tool_use\"}],\"model\":\"claude-opus-5-5\","
                          + "\"role\":\"assistant\",\"type\":\"message\"}" + tail + Self.timestamp(atMs)
                          + "\",\"type\":\"assistant\",\"uuid\":\"\(Self.uuid(&rng))\"}\n")
            atMs = min(atMs + 1_000 + Int64(rng.below(4_000)), spec.endMs)
            messages += 2

            let output = isCommit ? 120 : toolOutputBytes(isLarge: spec.isLarge, rng: &rng)
            if output >= 1 << 20 {
                longLines += 1
            }
            // Real tool results carry the output twice: in the message and in `toolUseResult`.
            writer.append(head + "{\"content\":[{\"content\":\"")
            writer.appendBulk(pools.bulk, count: output / 2, rng: &rng)
            writer.append("\",\"tool_use_id\":\"\(toolID)\",\"type\":\"tool_result\"}],\"role\":\"user\"}"
                          + tail + Self.timestamp(atMs)
                          + "\",\"toolUseResult\":{\"interrupted\":false,\"stderr\":\"\",\"stdout\":\"")
            writer.appendBulk(pools.bulk, count: output - output / 2, rng: &rng)
            writer.append("\"},\"type\":\"user\",\"uuid\":\"\(Self.uuid(&rng))\"}\n")
            atMs = min(atMs + 1_000 + Int64(rng.below(4_000)), spec.endMs)
        }
        try writer.close()
        return (writer.written, messages, longLines)
    }

    /// Mostly a few KB; 7.5 % tens of KB; in large sessions 1.5 % are 1–12 MB.
    private func toolOutputBytes(isLarge: Bool, rng: inout HistorySplitMix64) -> Int {
        if isLarge, rng.chance(0.015) {
            return (1 << 20) + rng.below(11 << 20)
        }
        if rng.chance(0.075) {
            return Self.clamp(rng.logNormal(median: 40_000, sigma: 0.8), 8_000, 600_000)
        }
        return Self.clamp(rng.logNormal(median: 2_500, sigma: 0.8), 60, 30_000)
    }

    private static let commands = [
        "swift test --filter BenchSuite", "rg -n bench Sources", "git status --short", "make lint",
        "ls -la Sources/App", "cat Package.swift", "xcodebuild build -scheme Bench", "git diff --stat",
    ]

    // MARK: - Pools

    /// Text for prompts and replies (Zipf words) and for tool output (log-like lines); both
    /// ASCII without quotes, backslashes or control characters.
    private struct Pools {
        let text: [UInt8]
        let bulk: [UInt8]

        init(rng: inout HistorySplitMix64) {
            let words = HistorySyntheticCorpus(.small)
            var text = ""
            text.reserveCapacity(2 << 20)
            while text.utf8.count < 2 << 20 {
                text += words.zipfWord(&rng)
                text += rng.chance(0.08) ? ". " : " "
            }
            var bulk = ""
            bulk.reserveCapacity(1 << 20)
            while bulk.utf8.count < 1 << 20 {
                bulk += "[\(rng.below(99_999))] \(words.zipfWord(&rng))/\(words.zipfWord(&rng)).swift:"
                bulk += "\(rng.below(900)) \(words.zipfWord(&rng)) = 0x\(rng.hex(8)) (\(rng.below(100)) ms) "
            }
            self.text = Array(text.utf8)
            self.bulk = Array(bulk.utf8)
        }
    }

    /// Appends to a file through a 4 MB buffer; `written` counts every byte appended.
    private final class BufferedWriter {
        private let descriptor: Int32
        private var buffer: [UInt8] = []
        private(set) var written: Int64 = 0

        init(url: URL) throws {
            descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            buffer.reserveCapacity(4 << 20)
        }

        deinit {
            Darwin.close(descriptor)
        }

        func append(_ string: String) {
            buffer.append(contentsOf: string.utf8)
            written += Int64(string.utf8.count)
            flushIfNeeded()
        }

        func append(_ pool: [UInt8], offset: Int, count: Int) {
            let end = min(offset + count, pool.count)
            buffer.append(contentsOf: pool[offset..<end])
            written += Int64(end - offset)
            flushIfNeeded()
        }

        /// `count` bytes from `pool`, wrapping around for outputs larger than the pool.
        func appendBulk(_ pool: [UInt8], count: Int, rng: inout HistorySplitMix64) {
            var remaining = count
            var offset = rng.below(pool.count)
            while remaining > 0 {
                let chunk = min(remaining, pool.count - offset)
                append(pool, offset: offset, count: chunk)
                remaining -= chunk
                offset = 0
            }
        }

        func close() throws {
            try flush()
        }

        private func flushIfNeeded() {
            if buffer.count >= 4 << 20 {
                try? flush()
            }
        }

        private func flush() throws {
            var start = 0
            while start < buffer.count {
                let count = buffer[start...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                guard count > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                start += count
            }
            buffer.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - Formatting

    static func projectURL(_ claudeRoot: URL, cwd: String) -> URL {
        claudeRoot.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(AgentHistoryFixtures.claudeProjectDirectoryName(cwd), isDirectory: true)
    }

    private static func clamp(_ value: Double, _ low: Int, _ high: Int) -> Int {
        min(max(Int(value), low), high)
    }

    private static func hex(_ value: UInt64) -> String {
        String(format: "%016llx", value)
    }

    private static func uuid(_ rng: inout HistorySplitMix64) -> String {
        let high = rng.next()
        let low = rng.next()
        return String(format: "%08llx-%04llx-4%03llx-a%03llx-%012llx",
                      high >> 32, (high >> 16) & 0xFFFF, high & 0xFFF, (low >> 48) & 0xFFF, low & 0xFFFF_FFFF_FFFF)
    }

    /// `2026-11-01T10:00:00.123Z`, the shape Claude Code writes.
    private static func timestamp(_ ms: Int64) -> String {
        var seconds = time_t(ms / 1_000)
        var parts = tm()
        gmtime_r(&seconds, &parts)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                      parts.tm_year + 1_900, parts.tm_mon + 1, parts.tm_mday,
                      parts.tm_hour, parts.tm_min, parts.tm_sec, Int32(ms % 1_000))
    }
}
