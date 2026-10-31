import Foundation

/// One `turn_started` record of a Grok session's `events.jsonl`.
struct GrokTurnStart: Equatable, Sendable {
    let turnNumber: Int?
    let atMs: Int64

    /// The first turn start strictly after `lastMs` whose `turn_number` equals `promptIndex`
    /// (any turn number when `promptIndex` is nil). Matching by number survives compaction,
    /// which drops early prompts from the chat history but not from the event log; "after the
    /// previous match" keeps a resumed session whose numbering restarted in order.
    static func match(in turns: [GrokTurnStart], promptIndex: Int?, after lastMs: Int64?) -> Int64? {
        let floor = lastMs ?? Int64.min
        return turns.first { turn in
            turn.atMs > floor && (promptIndex == nil || turn.turnNumber == promptIndex)
        }?.atMs
    }
}

/// `turn_started` times per `events.jsonl`, read incrementally.
///
/// The event log is mostly `phase_changed` noise (often megabytes), so lines are prefiltered
/// with `memmem` for `"turn_started"` before decoding, and each file's parsed prefix is cached
/// by dev/inode, offset and the fingerprint before it: a grown file is read from where the last
/// read stopped, a replaced, truncated or rewritten one from the start. Thread-safe (`NSLock`); reads happen outside the lock.
final class GrokTurnTimelineCache: @unchecked Sendable {
    static let maxEntries = 512
    private static let needle = "\"turn_started\""

    private struct Entry {
        let dev: Int64
        let ino: Int64
        let offset: Int64
        let fingerprint: Int64?
        let turns: [GrokTurnStart]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Every turn start of the file in log order; empty when it is missing or unreadable.
    func turns(eventsPath path: String) -> [GrokTurnStart] {
        guard let identity = AgentHistoryFileIdentity.stat(path: path) else {
            lock.withLock { _ = entries.removeValue(forKey: path) }
            return []
        }
        let cached = lock.withLock { entries[path] }
        var turns: [GrokTurnStart] = []
        var offset: Int64 = 0
        if let cached, cached.dev == identity.dev, cached.ino == identity.ino, cached.offset <= identity.size,
           AgentHistoryFileFingerprint.compute(path: path, endOffset: cached.offset) == cached.fingerprint {
            turns = cached.turns
            offset = cached.offset
        }
        if offset < identity.size {
            guard let read = Self.read(path: path, from: offset) else {
                return turns
            }
            turns += read.turns
            offset = read.committedOffset
        }
        let entry = Entry(
            dev: identity.dev,
            ino: identity.ino,
            offset: offset,
            fingerprint: AgentHistoryFileFingerprint.compute(path: path, endOffset: offset),
            turns: turns
        )
        lock.withLock {
            if entries.count >= Self.maxEntries, entries[path] == nil {
                entries.removeAll(keepingCapacity: true)
            }
            entries[path] = entry
        }
        return turns
    }

    /// The byte offset cached for `path`, up to which its turns are known; nil without an entry.
    func cachedOffset(eventsPath path: String) -> Int64? {
        lock.withLock { entries[path]?.offset }
    }

    private static func read(path: String, from offset: Int64) -> (turns: [GrokTurnStart], committedOffset: Int64)? {
        guard let source = try? FileByteSource(path: path, offset: offset) else {
            return nil
        }
        var reader = JSONLTailReader(source: source, startOffset: offset)
        var turns: [GrokTurnStart] = []
        guard let stats = try? reader.readLines({ line, _ in
            if JSONLineSniffer.contains(needle, in: line), let turn = turnStart(line) {
                turns.append(turn)
            }
            return .continue
        }) else {
            return nil
        }
        return (turns, stats.committedOffset)
    }

    private static func turnStart(_ line: UnsafeRawBufferPointer) -> GrokTurnStart? {
        guard
            let base = line.baseAddress,
            let object = try? JSONSerialization.jsonObject(with: Data(bytes: base, count: line.count)) as? [String: Any],
            (object["type"] as? String) == "turn_started",
            let ts = object["ts"] as? String,
            let atMs = AgentHistoryTimestamp.milliseconds(iso8601: ts)
        else {
            return nil
        }
        return GrokTurnStart(turnNumber: (object["turn_number"] as? NSNumber)?.intValue, atMs: atMs)
    }
}
