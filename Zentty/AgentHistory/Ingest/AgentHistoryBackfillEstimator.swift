import Foundation

/// Rough time left in a backfill, from the pace over the last couple of minutes. Sessions vary a
/// lot in size, so a recent window beats an average since the start, and the UI says "about".
/// Paused time doesn't count: the indexer resets this while it's paused.
struct AgentHistoryBackfillEstimator: Sendable {
    /// Pace older than this no longer says much about the sessions still queued.
    static let window: TimeInterval = 120
    /// No number before this much work: the first sessions are too few to judge a pace by.
    static let minimumSpan: TimeInterval = 10
    static let minimumSessions = 10

    private struct Sample: Sendable {
        let uptime: TimeInterval
        let indexed: Int
    }

    private var samples: [Sample] = []

    mutating func reset() {
        samples.removeAll()
    }

    mutating func record(indexed: Int, at uptime: TimeInterval) {
        if let last = samples.last {
            if indexed < last.indexed {
                // Sessions were removed mid-run, so the count no longer measures progress.
                samples.removeAll()
            } else if uptime - last.uptime < 1, samples.count > 1 {
                samples[samples.count - 1] = Sample(uptime: uptime, indexed: indexed)
                trim(now: uptime)
                return
            }
        }
        samples.append(Sample(uptime: uptime, indexed: indexed))
        trim(now: uptime)
    }

    /// Seconds until `sessionsLeft` are done at the recent pace; nil until there's a pace to use.
    func secondsRemaining(sessionsLeft: Int, at uptime: TimeInterval) -> TimeInterval? {
        guard sessionsLeft > 0, let first = samples.first, let last = samples.last else {
            return nil
        }
        let span = uptime - first.uptime
        let sessions = last.indexed - first.indexed
        guard span >= Self.minimumSpan, sessions >= Self.minimumSessions else {
            return nil
        }
        return Double(sessionsLeft) * span / Double(sessions)
    }

    private mutating func trim(now: TimeInterval) {
        let cutoff = now - Self.window
        while samples.count > 1, samples[1].uptime <= cutoff {
            samples.removeFirst()
        }
    }
}
