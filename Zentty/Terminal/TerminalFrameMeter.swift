import Foundation
import OSLog

@MainActor
final class TerminalFrameMeter {
    enum SampleKind: String, Equatable {
        case tick
        case offset
        case sent
    }

    enum Severity: Equatable {
        case stable
        case warning
        case critical

        var isDip: Bool {
            self != .stable
        }

        static func classify(framesPerSecond: Double, preferredFramesPerSecond: Int) -> Severity {
            let target = Double(max(1, preferredFramesPerSecond))
            if framesPerSecond < target * 0.30 {
                return .critical
            }
            if framesPerSecond < target * 0.50 {
                return .warning
            }
            return .stable
        }
    }

    struct HistoryPoint: Equatable {
        let timestamp: TimeInterval
        let framesPerSecond: Double?
        let severity: Severity

        var isDip: Bool {
            severity.isDip
        }
    }

    struct Sample: Equatable {
        let paneID: PaneID
        let timestamp: TimeInterval
        let rowOffset: Double
        let preferredFramesPerSecond: Int
        let displayID: UInt32?
        let isLiveScrolling: Bool
        let sampleKind: SampleKind
        let pacingMode: TerminalScrollFramePacingMode
    }

    struct Snapshot: Equatable {
        let paneID: PaneID
        let tickFramesPerSecond: Double?
        let offsetFramesPerSecond: Double?
        let sentFramesPerSecond: Double?
        let preferredFramesPerSecond: Int
        let lateFrameRatio: Double
        let maxDeltaMilliseconds: Double?
        let rowOffset: Double
        let displayID: UInt32?
        let isLiveScrolling: Bool
        let sampleKind: SampleKind
        let pacingMode: TerminalScrollFramePacingMode
        let historyPoints: [HistoryPoint]

        var framesPerSecond: Double? {
            tickFramesPerSecond
        }
    }

    static let shared = TerminalFrameMeter()
    static let stateDidChangeNotification = Notification.Name("TerminalFrameMeterStateDidChange")

    var isEnabled = false {
        didSet {
            guard oldValue != isEnabled else {
                return
            }
            reset()
            logger.notice("terminal frame meter \(self.isEnabled ? "enabled" : "disabled", privacy: .public)")
            NotificationCenter.default.post(name: Self.stateDidChangeNotification, object: self)
        }
    }

    private struct PaneStats {
        var windowStartedAt: TimeInterval
        var lastTimestamp: TimeInterval?
        var tickFrameCount = 0
        var offsetFrameCount = 0
        var sentFrameCount = 0
        var lateFrameCount = 0
        var mainDeltaMaxMilliseconds: Double = 0
        var latestRowOffset: Double = 0
        var displayID: UInt32?
        var preferredFramesPerSecond: Int
        var isLiveScrolling = false
        var sampleKind: SampleKind = .tick
        var pacingMode: TerminalScrollFramePacingMode = .stopped
        var lastTickTimestamp: TimeInterval?
        var historyPoints: [HistoryPoint] = []
    }

    private let logger = Logger(subsystem: "be.zenjoy.zentty", category: "TerminalFrameMeter")
    private var samples: [Sample] = []
    private var statsByPane: [PaneID: PaneStats] = [:]
    private var latestSnapshotsByPane: [PaneID: Snapshot] = [:]
    private let sampleLimit = 2_000
    private let historyWindowSeconds: TimeInterval = 5
    private var nowOverride: TimeInterval?

    @discardableResult
    func recordScrollFrameSample(
        paneID: PaneID,
        rowOffset: Double,
        preferredFramesPerSecond: Int,
        displayID: UInt32?,
        isLiveScrolling: Bool,
        sampleKind: SampleKind,
        pacingMode: TerminalScrollFramePacingMode
    ) -> Snapshot? {
        guard isEnabled else {
            return nil
        }

        let now = currentTime()
        let sample = Sample(
            paneID: paneID,
            timestamp: now,
            rowOffset: rowOffset,
            preferredFramesPerSecond: preferredFramesPerSecond,
            displayID: displayID,
            isLiveScrolling: isLiveScrolling,
            sampleKind: sampleKind,
            pacingMode: pacingMode
        )
        samples.append(sample)
        if samples.count > sampleLimit {
            samples.removeFirst(samples.count - sampleLimit)
        }

        return updateStats(with: sample)
    }

    private func updateStats(with sample: Sample) -> Snapshot {
        let preferredFramesPerSecond = max(1, sample.preferredFramesPerSecond)
        var stats = statsByPane[sample.paneID] ?? PaneStats(
            windowStartedAt: sample.timestamp,
            preferredFramesPerSecond: preferredFramesPerSecond
        )

        if sample.sampleKind == .tick {
            if let lastTickTimestamp = stats.lastTickTimestamp {
                let delta = sample.timestamp - lastTickTimestamp
                let targetFrameDuration = 1.0 / Double(preferredFramesPerSecond)
                if delta > targetFrameDuration * 1.5 {
                    stats.lateFrameCount += 1
                }
                stats.mainDeltaMaxMilliseconds = max(stats.mainDeltaMaxMilliseconds, delta * 1_000)
            }

            let historyPoint = tickHistoryPoint(
                timestamp: sample.timestamp,
                previousTimestamp: stats.lastTickTimestamp,
                preferredFramesPerSecond: preferredFramesPerSecond
            )
            stats.historyPoints.append(historyPoint)
            stats.historyPoints.removeAll { sample.timestamp - $0.timestamp > historyWindowSeconds }
            stats.lastTickTimestamp = sample.timestamp
            stats.tickFrameCount += 1
        }

        switch sample.sampleKind {
        case .tick:
            break
        case .offset:
            stats.offsetFrameCount += 1
        case .sent:
            stats.sentFrameCount += 1
        }
        stats.lastTimestamp = sample.timestamp
        stats.latestRowOffset = sample.rowOffset
        stats.displayID = sample.displayID
        stats.preferredFramesPerSecond = preferredFramesPerSecond
        stats.isLiveScrolling = sample.isLiveScrolling
        stats.sampleKind = sample.sampleKind
        stats.pacingMode = sample.pacingMode

        let elapsed = sample.timestamp - stats.windowStartedAt
        let effectiveElapsed = elapsed > 0 ? elapsed : 1
        let snapshot = Snapshot(
            paneID: sample.paneID,
            tickFramesPerSecond: framesPerSecond(count: stats.tickFrameCount, elapsed: effectiveElapsed),
            offsetFramesPerSecond: framesPerSecond(count: stats.offsetFrameCount, elapsed: effectiveElapsed),
            sentFramesPerSecond: framesPerSecond(count: stats.sentFrameCount, elapsed: effectiveElapsed),
            preferredFramesPerSecond: preferredFramesPerSecond,
            lateFrameRatio: stats.tickFrameCount > 0 ? Double(stats.lateFrameCount) / Double(stats.tickFrameCount) : 0,
            maxDeltaMilliseconds: stats.mainDeltaMaxMilliseconds > 0 ? stats.mainDeltaMaxMilliseconds : nil,
            rowOffset: stats.latestRowOffset,
            displayID: stats.displayID,
            isLiveScrolling: stats.isLiveScrolling,
            sampleKind: stats.sampleKind,
            pacingMode: stats.pacingMode,
            historyPoints: stats.historyPoints
        )
        latestSnapshotsByPane[sample.paneID] = snapshot

        if elapsed >= 1.0 {
            #if DEBUG
            let tickFPS = Double(stats.tickFrameCount) / elapsed
            let offsetFPS = Double(stats.offsetFrameCount) / elapsed
            let sentFPS = Double(stats.sentFrameCount) / elapsed
            logger.log(
                "pane=\(sample.paneID.rawValue, privacy: .public) tickFPS=\(tickFPS, format: .fixed(precision: 1)) offsetFPS=\(offsetFPS, format: .fixed(precision: 1)) sentFPS=\(sentFPS, format: .fixed(precision: 1)) target=\(preferredFramesPerSecond, privacy: .public) late=\(stats.lateFrameCount, privacy: .public)/\(stats.tickFrameCount, privacy: .public) maxDeltaMs=\(stats.mainDeltaMaxMilliseconds, format: .fixed(precision: 2)) rowOffset=\(stats.latestRowOffset, format: .fixed(precision: 2)) displayID=\(stats.displayID.map(String.init) ?? "nil", privacy: .public) live=\(stats.isLiveScrolling, privacy: .public) pacing=\(stats.pacingMode.rawValue, privacy: .public)"
            )
            #endif
            stats = PaneStats(
                windowStartedAt: sample.timestamp,
                lastTimestamp: sample.timestamp,
                preferredFramesPerSecond: preferredFramesPerSecond,
                sampleKind: sample.sampleKind,
                pacingMode: sample.pacingMode
            )
            stats.historyPoints = snapshot.historyPoints
            stats.lastTickTimestamp = snapshot.historyPoints.last?.timestamp
        }

        statsByPane[sample.paneID] = stats
        return snapshot
    }

    private func tickHistoryPoint(
        timestamp: TimeInterval,
        previousTimestamp: TimeInterval?,
        preferredFramesPerSecond: Int
    ) -> HistoryPoint {
        guard let previousTimestamp else {
            return HistoryPoint(timestamp: timestamp, framesPerSecond: nil, severity: .stable)
        }

        let delta = timestamp - previousTimestamp
        guard delta > 0 else {
            return HistoryPoint(timestamp: timestamp, framesPerSecond: nil, severity: .stable)
        }

        let framesPerSecond = 1.0 / delta
        let severity = Severity.classify(
            framesPerSecond: framesPerSecond,
            preferredFramesPerSecond: preferredFramesPerSecond
        )
        return HistoryPoint(timestamp: timestamp, framesPerSecond: framesPerSecond, severity: severity)
    }

    private func framesPerSecond(count: Int, elapsed: TimeInterval) -> Double? {
        guard count > 0 else {
            return nil
        }

        return Double(count) / elapsed
    }

    private func reset() {
        samples.removeAll(keepingCapacity: true)
        statsByPane.removeAll(keepingCapacity: true)
        latestSnapshotsByPane.removeAll(keepingCapacity: true)
    }

    private func currentTime() -> TimeInterval {
        nowOverride ?? ProcessInfo.processInfo.systemUptime
    }

    func resetForTesting() {
        reset()
    }

    func setNowForTesting(_ now: TimeInterval) {
        nowOverride = now
    }

    func clearNowForTesting() {
        nowOverride = nil
    }

    func samplesForTesting() -> [Sample] {
        samples
    }

    func latestSnapshot(for paneID: PaneID) -> Snapshot? {
        latestSnapshotsByPane[paneID]
    }
}
