import Foundation
import OSLog

enum ZenttyPerformanceSignposts {
    private static let signposter = OSSignposter(
        subsystem: "be.zenjoy.zentty",
        category: .pointsOfInterest
    )

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer {
            signposter.endInterval(name, state)
        }
        return try body()
    }
}

struct TerminalMetadata: Equatable {
    var title: String?
    var currentWorkingDirectory: String?
    var processName: String?
    var gitBranch: String?
}

extension TerminalMetadata {
    var hasRenderableContext: Bool {
        [title, currentWorkingDirectory, processName]
            .contains { value in
                guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return false
                }

                return !trimmed.isEmpty
            }
    }
}

enum TerminalMetadataChangeKind: Equatable {
    case noop
    case volatileTitleOnly
    case meaningful
}

enum TerminalMetadataChangeClassifier {
    enum VolatileAgentStatusPhase: Equatable {
        case running
        case starting
        case needsInput
        case idle
    }

    enum CodexWaitingTitleKind: Equatable {
        case backgroundWait
        case needsInput
    }

    struct VolatileAgentStatusTitleSignature: Equatable {
        let phase: VolatileAgentStatusPhase
        let subject: String
    }

    private struct ParsedVolatileAgentStatusTitle: Equatable {
        let phase: VolatileAgentStatusPhase
        let displaySubject: String
    }

    static func classify(previous: TerminalMetadata?, next: TerminalMetadata) -> TerminalMetadataChangeKind {
        guard previous != next else {
            return .noop
        }

        guard let previous else {
            return .meaningful
        }

        guard previous.currentWorkingDirectory == next.currentWorkingDirectory,
              previous.processName == next.processName,
              previous.gitBranch == next.gitBranch else {
            return .meaningful
        }

        let previousTool = AgentToolRecognizer.recognize(metadata: previous)
        let nextTool = AgentToolRecognizer.recognize(metadata: next)
        guard previousTool == nextTool else {
            return .meaningful
        }

        if let previousSignature = realtimeAgentTitleSignature(
            previous.title,
            recognizedTool: previousTool
        ),
           let nextSignature = realtimeAgentTitleSignature(
            next.title,
            recognizedTool: nextTool
           ),
           previousSignature == nextSignature {
            return .volatileTitleOnly
        }

        return .meaningful
    }

    static func volatileAgentStatusTitleSignature(
        _ value: String?,
        recognizedTool: AgentTool?
    ) -> VolatileAgentStatusTitleSignature? {
        guard recognizedTool == .codex,
              let normalized = WorklaneContextFormatter.trimmed(value),
              let parsed = parseAgentStatusTitle(
                  normalized,
                  runningWords: ["working", "thinking"],
                  startingWords: ["starting"],
                  needsInputWords: ["waiting"],
                  idleWords: ["ready"]
              ) else {
            return nil
        }

        let phase: VolatileAgentStatusPhase
        switch codexWaitingTitleKind(for: normalized) {
        case .backgroundWait:
            phase = .idle
        case .needsInput:
            phase = .needsInput
        case nil:
            phase = parsed.phase
        }

        return VolatileAgentStatusTitleSignature(
            phase: phase,
            subject: parsed.displaySubject.lowercased()
        )
    }

    static func volatileAgentStatusDisplaySubject(
        _ value: String?,
        recognizedTool: AgentTool?
    ) -> String? {
        guard recognizedTool == .codex,
              let normalized = WorklaneContextFormatter.trimmed(value),
              let parsed = parseAgentStatusTitle(
                  normalized,
                  runningWords: ["working", "thinking"],
                  startingWords: ["starting"],
                  needsInputWords: ["waiting"],
                  idleWords: ["ready"]
              ) else {
            return nil
        }

        guard parsed.displaySubject.caseInsensitiveCompare("zentty") != .orderedSame else {
            return nil
        }

        return parsed.displaySubject
    }

    static func diagnosticAgentStatusTitleSignature(
        _ value: String?,
        recognizedTool: AgentTool?
    ) -> VolatileAgentStatusTitleSignature? {
        guard let normalized = WorklaneContextFormatter.trimmed(value) else {
            return nil
        }

        switch recognizedTool {
        case .codex:
            return volatileAgentStatusTitleSignature(normalized, recognizedTool: .codex)
        case .claudeCode:
            // Claude Code 2.x encodes status in the title glyph: "✳" (U+2733)
            // on the idle prompt, braille spinner glyphs (U+2800…U+28FF) while
            // the agent is thinking. After a user interrupt (Escape) the
            // spinner is replaced by "✳", with the subject left intact — this
            // is what lets us detect the interrupt when no Stop hook fires.
            if let signature = parseClaudeCodeGlyphTitle(normalized) {
                return signature
            }

            // Fallback: older Claude Code builds used English words
            // ("Thinking …", "Interrupted · …") as the title prefix. Keep
            // detection for those so downgrades stay covered.
            guard let parsed = parseAgentStatusTitle(
                normalized,
                runningWords: ["thinking", "working", "responding", "analyzing"],
                startingWords: ["starting"],
                idleWords: ["ready", "waiting", "interrupted"]
            ) else {
                return nil
            }

            return VolatileAgentStatusTitleSignature(
                phase: parsed.phase,
                subject: parsed.displaySubject.lowercased()
            )
        default:
            return nil
        }
    }

    static func realtimeAgentTitleSignature(
        _ value: String?,
        recognizedTool: AgentTool?
    ) -> VolatileAgentStatusTitleSignature? {
        switch recognizedTool {
        case .codex:
            return volatileAgentStatusTitleSignature(value, recognizedTool: .codex)
        case .claudeCode:
            return diagnosticAgentStatusTitleSignature(value, recognizedTool: .claudeCode)
        default:
            return nil
        }
    }

    static func wouldTreatAsVolatileClaudeTransition(
        previous: TerminalMetadata?,
        next: TerminalMetadata
    ) -> Bool {
        guard let previous else {
            return false
        }

        let previousTool = AgentToolRecognizer.recognize(metadata: previous)
        let nextTool = AgentToolRecognizer.recognize(metadata: next)
        guard previousTool == .claudeCode, nextTool == .claudeCode else {
            return false
        }

        guard previous.title != next.title else {
            return false
        }

        return diagnosticAgentStatusTitleSignature(previous.title, recognizedTool: previousTool)
            == diagnosticAgentStatusTitleSignature(next.title, recognizedTool: nextTool)
    }

    static func isVolatileAgentStatusTitle(
        _ value: String?,
        recognizedTool: AgentTool?
    ) -> Bool {
        volatileAgentStatusTitleSignature(value, recognizedTool: recognizedTool) != nil
    }

    static func isRealtimeAgentStatusTitle(
        _ value: String?,
        recognizedTool: AgentTool?
    ) -> Bool {
        realtimeAgentTitleSignature(value, recognizedTool: recognizedTool) != nil
    }

    static func codexWaitingTitleKind(for value: String?) -> CodexWaitingTitleKind? {
        guard let normalized = WorklaneContextFormatter.trimmed(value) else {
            return nil
        }

        let firstWord = normalized.prefix(while: { $0.isLetter }).lowercased()
        guard firstWord == "waiting" else {
            return nil
        }

        if AgentInteractionClassifier.requiresHumanInput(message: normalized) {
            return .needsInput
        }

        return .backgroundWait
    }

    private static func parseClaudeCodeGlyphTitle(
        _ normalized: String
    ) -> VolatileAgentStatusTitleSignature? {
        guard let first = normalized.unicodeScalars.first else {
            return nil
        }

        let phase: VolatileAgentStatusPhase
        switch first.value {
        case 0x2733:
            phase = .idle
        case 0x2800...0x28FF:
            phase = .running
        default:
            return nil
        }

        let remainder = normalized
            .dropFirst()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            return nil
        }

        return VolatileAgentStatusTitleSignature(
            phase: phase,
            subject: remainder.lowercased()
        )
    }

    private static func parseAgentStatusTitle(
        _ normalized: String,
        runningWords: Set<String>,
        startingWords: Set<String>,
        needsInputWords: Set<String> = [],
        idleWords: Set<String>
    ) -> ParsedVolatileAgentStatusTitle? {
        let firstWord = normalized.prefix(while: { $0.isLetter }).lowercased()
        let phase: VolatileAgentStatusPhase
        if runningWords.contains(firstWord) {
            phase = .running
        } else if startingWords.contains(firstWord) {
            phase = .starting
        } else if needsInputWords.contains(firstWord) {
            phase = .needsInput
        } else if idleWords.contains(firstWord) {
            phase = .idle
        } else {
            return nil
        }

        var remainder = normalized.dropFirst(firstWord.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            return nil
        }

        if let firstToken = remainder.split(whereSeparator: \.isWhitespace).first,
           firstToken.contains(where: \.isLetter) == false,
           firstToken.contains(where: \.isNumber) == false {
            remainder = remainder.dropFirst(firstToken.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !remainder.isEmpty else {
            return nil
        }

        return ParsedVolatileAgentStatusTitle(
            phase: phase,
            displaySubject: remainder
        )
    }
}

enum TerminalMetadataDeliveryOutcome: String, Equatable, Sendable {
    case immediate
    case coalesced
    case droppedNoop = "dropped_noop"
}

enum TerminalDiagnosticsRenderKind: String, Sendable {
    case full
    case sidebar
    case header
    case canvas
}

private let terminalDiagnosticsLogger = Logger(subsystem: "be.zenjoy.zentty", category: "TerminalDiagnostics")

final class TerminalDiagnostics: @unchecked Sendable {
    enum Scope: Hashable, Equatable, Sendable {
        case runtime
        case pane(PaneID)

        var label: String {
            switch self {
            case .runtime:
                return "runtime"
            case .pane(let paneID):
                return "pane:\(paneID.rawValue)"
            }
        }
    }

    struct BurstSummary: Equatable, Sendable {
        let scope: Scope
        var startedAt: Date
        var endedAt: Date
        var commandHint: String?
        var wakeupCount = 0
        var wakeupEnqueueCount = 0
        var tickCount = 0
        var tickTotalMilliseconds: Double = 0
        var tickMaxMilliseconds: Double = 0
        var mainQueueDelayTotalMilliseconds: Double = 0
        var mainQueueDelayMaxMilliseconds: Double = 0
        var actionCallbackCount = 0
        var actionDrainCount = 0
        var actionDrainQueueDelayTotalMilliseconds: Double = 0
        var actionDrainQueueDelayMaxMilliseconds: Double = 0
        var scrollbarApplyCount = 0
        var scrollbarApplyTotalMilliseconds: Double = 0
        var scrollbarApplyMaxMilliseconds: Double = 0
        var scrollHostSyncCount = 0
        var scrollHostSyncTotalMilliseconds: Double = 0
        var scrollHostSyncMaxMilliseconds: Double = 0
        var scrollbarGeometryApplyCount = 0
        var documentHeightChangeCount = 0
        var documentHeightMaxPoints: Double = 0
        var documentHeightMaxDeltaPoints: Double = 0
        var scrollbarBottomAlignedCount = 0
        var scrollbarOffBottomCount = 0
        var scrollbarWasAtBottomCount = 0
        var scrollbarAutoFollowEligibleCount = 0
        var scrollbarAutoFollowSuppressedCount = 0
        var scrollbarAutoFollowAppliedCount = 0
        var scrollbarUserScrolledAwayCount = 0
        var scrollbarExplicitSyncAllowedCount = 0
        var scrollbarMaxTotalRows: UInt64 = 0
        var scrollbarMinOffsetRows: UInt64?
        var scrollbarMaxOffsetRows: UInt64 = 0
        var scrollbarMinVisibleRows: UInt64?
        var scrollbarMaxVisibleRows: UInt64 = 0
        var firstScrollbarPosition: String?
        var lastScrollbarPosition: String?
        var replaySuppressionEnterCount = 0
        var replaySuppressionExitCount = 0
        var replaySuppressionTotalMilliseconds: Double = 0
        var replaySuppressionReasonCounts: [String: Int] = [:]
        var occlusionVisibleCount = 0
        var occlusionHiddenCount = 0
        var reflectScrolledClipViewCount = 0
        var scrollToRowActionCount = 0
        var viewportSyncCount = 0
        var viewportSyncTotalMilliseconds: Double = 0
        var viewportSyncMaxMilliseconds: Double = 0
        var actionPayloadCounts: [String: Int] = [:]
        var metadataDeliveryCount = 0
        var metadataChangeKindCounts: [String: Int] = [:]
        var metadataToolCounts: [String: Int] = [:]
        var titleChangeCount = 0
        var claudeTitleChangeCount = 0
        var codexTitleChangeCount = 0
        var wouldHaveBeenVolatileClaudeCount = 0
        var storeUpdateCount = 0
        var storeFastPathCount = 0
        var auxiliaryInvalidationCounts: [String: Int] = [:]
        var renderCounts: [String: Int] = [:]
        var visiblePaneCount: Int?
        var liveRuntimeCount: Int?
        var windowVisible: Bool?
        var windowKey: Bool?
        var firstTitle: String?
        var lastTitle: String?
        var uniqueTitleCount = 0

        fileprivate var uniqueTitles: Set<String> = []

        fileprivate mutating func recordTitle(_ title: String?) {
            guard let title = WorklaneContextFormatter.trimmed(title) else {
                return
            }

            if firstTitle == nil {
                firstTitle = title
            }
            lastTitle = title
            if uniqueTitles.insert(title).inserted {
                uniqueTitleCount = uniqueTitles.count
            }
        }

    }

    static let shared: TerminalDiagnostics = {
        let diagnostics = TerminalDiagnostics()
        diagnostics.setEnabled(defaultSharedEnabled)
        return diagnostics
    }()

    var onEmit: ((BurstSummary) -> Void)?

    private struct BurstState {
        var summary: BurstSummary
        var lastEventAt: Date
        var flushWorkItem: DispatchWorkItem?
    }

    private let quietPeriod: TimeInterval
    private let queue = DispatchQueue(label: "be.zenjoy.zentty.terminal-diagnostics", qos: .utility)
    private let deliverEmission: (@escaping () -> Void) -> Void
    private let enabledLock = NSLock()
    private var enabled = false
    private var burstsByScope: [Scope: BurstState] = [:]

    init(
        quietPeriod: TimeInterval = 1.0,
        deliverEmission: @escaping (@escaping () -> Void) -> Void = {
            DispatchQueue.main.async(execute: $0)
        }
    ) {
        self.quietPeriod = quietPeriod
        self.deliverEmission = deliverEmission
    }

    func setEnabled(_ enabled: Bool) {
        enabledLock.lock()
        self.enabled = enabled
        enabledLock.unlock()

        guard enabled == false else {
            return
        }

        queue.async { [weak self] in
            guard let self else {
                return
            }
            guard self.isEnabled == false else {
                return
            }

            self.burstsByScope.values.forEach { $0.flushWorkItem?.cancel() }
            self.burstsByScope.removeAll()
        }
    }

    func recordWakeupReceived() {
        record(scope: .runtime) { summary in
            summary.wakeupCount += 1
        }
    }

    func recordWakeupEnqueued() {
        record(scope: .runtime) { summary in
            summary.wakeupEnqueueCount += 1
        }
    }

    func recordTick(durationNanoseconds: UInt64, queueDelayNanoseconds: UInt64) {
        record(scope: .runtime) { summary in
            summary.tickCount += 1
            let duration = Self.milliseconds(from: durationNanoseconds)
            summary.tickTotalMilliseconds += duration
            summary.tickMaxMilliseconds = max(summary.tickMaxMilliseconds, duration)
            let queueDelay = Self.milliseconds(from: queueDelayNanoseconds)
            summary.mainQueueDelayTotalMilliseconds += queueDelay
            summary.mainQueueDelayMaxMilliseconds = max(summary.mainQueueDelayMaxMilliseconds, queueDelay)
        }
    }

    func recordActionCallback(paneID: PaneID, payload: LibghosttySurfaceActionPayload) {
        record(scope: .pane(paneID)) { summary in
            summary.actionCallbackCount += 1
            let key = Self.actionPayloadKey(for: payload)
            Self.increment(key, in: &summary.actionPayloadCounts)
            if case .setTitle(let title) = payload {
                summary.recordTitle(title)
            }
        }
    }

    func recordActionDrain(paneID: PaneID, queueDelayNanoseconds: UInt64 = 0) {
        record(scope: .pane(paneID)) { summary in
            summary.actionDrainCount += 1
            let queueDelay = Self.milliseconds(from: queueDelayNanoseconds)
            summary.actionDrainQueueDelayTotalMilliseconds += queueDelay
            summary.actionDrainQueueDelayMaxMilliseconds = max(
                summary.actionDrainQueueDelayMaxMilliseconds,
                queueDelay
            )
        }
    }

    func recordScrollbarApply(paneID: PaneID, durationNanoseconds: UInt64) {
        record(scope: .pane(paneID)) { summary in
            summary.scrollbarApplyCount += 1
            let duration = Self.milliseconds(from: durationNanoseconds)
            summary.scrollbarApplyTotalMilliseconds += duration
            summary.scrollbarApplyMaxMilliseconds = max(summary.scrollbarApplyMaxMilliseconds, duration)
        }
    }

    func recordScrollHostSync(
        paneID: PaneID,
        durationNanoseconds: UInt64,
        geometryApplied: Bool,
        documentHeightChanged: Bool,
        documentHeightPoints: CGFloat,
        documentHeightDeltaPoints: CGFloat,
        reflected: Bool,
        scrollbarTotalRows: UInt64?,
        scrollbarOffsetRows: UInt64?,
        scrollbarVisibleRows: UInt64?,
        wasAtBottom: Bool?,
        shouldAutoScroll: Bool?,
        autoScrollApplied: Bool?,
        userScrolledAwayFromBottom: Bool?,
        explicitScrollbarSyncAllowed: Bool?
    ) {
        record(scope: .pane(paneID)) { summary in
            summary.scrollHostSyncCount += 1
            let duration = Self.milliseconds(from: durationNanoseconds)
            summary.scrollHostSyncTotalMilliseconds += duration
            summary.scrollHostSyncMaxMilliseconds = max(summary.scrollHostSyncMaxMilliseconds, duration)
            if geometryApplied {
                summary.scrollbarGeometryApplyCount += 1
            }
            if documentHeightChanged {
                summary.documentHeightChangeCount += 1
            }
            summary.documentHeightMaxPoints = max(summary.documentHeightMaxPoints, Double(documentHeightPoints))
            summary.documentHeightMaxDeltaPoints = max(summary.documentHeightMaxDeltaPoints, Double(documentHeightDeltaPoints))
            if reflected {
                summary.reflectScrolledClipViewCount += 1
            }
            if let total = scrollbarTotalRows, let offset = scrollbarOffsetRows, let visible = scrollbarVisibleRows {
                let position = "total:\(total),offset:\(offset),len:\(visible)"
                if summary.firstScrollbarPosition == nil {
                    summary.firstScrollbarPosition = position
                }
                summary.lastScrollbarPosition = position
                summary.scrollbarMaxTotalRows = max(summary.scrollbarMaxTotalRows, total)
                summary.scrollbarMinOffsetRows = min(summary.scrollbarMinOffsetRows ?? offset, offset)
                summary.scrollbarMaxOffsetRows = max(summary.scrollbarMaxOffsetRows, offset)
                summary.scrollbarMinVisibleRows = min(summary.scrollbarMinVisibleRows ?? visible, visible)
                summary.scrollbarMaxVisibleRows = max(summary.scrollbarMaxVisibleRows, visible)
                if Self.rowsBelowViewport(total: total, offset: offset, visible: visible) == 0 {
                    summary.scrollbarBottomAlignedCount += 1
                } else {
                    summary.scrollbarOffBottomCount += 1
                }
            }
            if wasAtBottom == true {
                summary.scrollbarWasAtBottomCount += 1
            }
            if shouldAutoScroll == true {
                summary.scrollbarAutoFollowEligibleCount += 1
            } else if shouldAutoScroll == false {
                summary.scrollbarAutoFollowSuppressedCount += 1
            }
            if autoScrollApplied == true {
                summary.scrollbarAutoFollowAppliedCount += 1
            }
            if userScrolledAwayFromBottom == true {
                summary.scrollbarUserScrolledAwayCount += 1
            }
            if explicitScrollbarSyncAllowed == true {
                summary.scrollbarExplicitSyncAllowedCount += 1
            }
        }
    }

    func recordScrollToRowAction(paneID: PaneID) {
        record(scope: .pane(paneID)) { summary in
            summary.scrollToRowActionCount += 1
        }
    }

    func recordReplaySuppressionEntered(paneID: PaneID, reason: String) {
        record(scope: .pane(paneID)) { summary in
            summary.replaySuppressionEnterCount += 1
            Self.increment(reason, in: &summary.replaySuppressionReasonCounts)
        }
    }

    func recordReplaySuppressionExited(paneID: PaneID, reason: String, durationNanoseconds: UInt64) {
        record(scope: .pane(paneID)) { summary in
            summary.replaySuppressionExitCount += 1
            summary.replaySuppressionTotalMilliseconds += Self.milliseconds(from: durationNanoseconds)
            Self.increment(reason, in: &summary.replaySuppressionReasonCounts)
        }
    }

    func recordOcclusionVisibility(paneID: PaneID, visible: Bool) {
        record(scope: .pane(paneID)) { summary in
            if visible {
                summary.occlusionVisibleCount += 1
            } else {
                summary.occlusionHiddenCount += 1
            }
        }
    }

    func recordViewportSync(paneID: PaneID, durationNanoseconds: UInt64) {
        record(scope: .pane(paneID)) { summary in
            summary.viewportSyncCount += 1
            let duration = Self.milliseconds(from: durationNanoseconds)
            summary.viewportSyncTotalMilliseconds += duration
            summary.viewportSyncMaxMilliseconds = max(summary.viewportSyncMaxMilliseconds, duration)
        }
    }

    func recordMetadataObservation(
        paneID: PaneID,
        previous: TerminalMetadata?,
        next: TerminalMetadata,
        changeKind: TerminalMetadataChangeKind,
        delivery: TerminalMetadataDeliveryOutcome
    ) {
        record(scope: .pane(paneID)) { summary in
            Self.increment(Self.metadataChangeKindKey(changeKind), in: &summary.metadataChangeKindCounts)
            let tool = AgentToolRecognizer.recognize(metadata: next)
            Self.increment(Self.toolKey(tool), in: &summary.metadataToolCounts)
            if summary.commandHint == nil {
                if let tool {
                    summary.commandHint = Self.toolKey(tool)
                } else {
                    summary.commandHint = WorklaneContextFormatter.trimmed(next.processName)
                }
            }

            if previous?.title != next.title {
                summary.titleChangeCount += 1
                switch tool {
                case .claudeCode:
                    summary.claudeTitleChangeCount += 1
                case .codex:
                    summary.codexTitleChangeCount += 1
                default:
                    break
                }
            }

            if TerminalMetadataChangeClassifier.wouldTreatAsVolatileClaudeTransition(
                previous: previous,
                next: next
            ) {
                summary.wouldHaveBeenVolatileClaudeCount += 1
            }

            summary.recordTitle(next.title)
        }
    }

    func recordMetadataDelivery(paneID: PaneID, outcome _: TerminalMetadataDeliveryOutcome) {
        record(scope: .pane(paneID)) { summary in
            summary.metadataDeliveryCount += 1
        }
    }

    func recordStoreMetadataUpdate(paneID: PaneID) {
        record(scope: .pane(paneID)) { summary in
            summary.storeUpdateCount += 1
        }
    }

    func recordStoreFastPath(paneID: PaneID) {
        record(scope: .pane(paneID)) { summary in
            summary.storeFastPathCount += 1
        }
    }

    func recordInvalidation(paneID: PaneID, impacts: WorklaneAuxiliaryInvalidation) {
        guard !impacts.isEmpty else {
            return
        }

        record(scope: .pane(paneID)) { summary in
            for key in Self.invalidationKeys(for: impacts) {
                Self.increment(key, in: &summary.auxiliaryInvalidationCounts)
            }
        }
    }

    func recordRender(_ kind: TerminalDiagnosticsRenderKind, activePaneID: PaneID?) {
        let scope: Scope = activePaneID.map { .pane($0) } ?? .runtime
        record(scope: scope) { summary in
            Self.increment(kind.rawValue, in: &summary.renderCounts)
        }
    }

    func recordRuntimeTopology(
        liveRuntimeCount: Int,
        visiblePaneCount: Int,
        windowVisible: Bool,
        windowKey: Bool
    ) {
        record(scope: .runtime) { summary in
            summary.liveRuntimeCount = liveRuntimeCount
            summary.visiblePaneCount = visiblePaneCount
            summary.windowVisible = windowVisible
            summary.windowKey = windowKey
        }
    }

    private func record(scope: Scope, update: @escaping @Sendable (inout BurstSummary) -> Void) {
        guard isEnabled else {
            return
        }

        queue.async { [weak self] in
            guard let self else {
                return
            }

            let now = Date()
            var burst = self.burstsByScope.removeValue(forKey: scope) ?? BurstState(
                summary: BurstSummary(scope: scope, startedAt: now, endedAt: now),
                lastEventAt: now,
                flushWorkItem: nil
            )

            if now.timeIntervalSince(burst.lastEventAt) > self.quietPeriod {
                burst.flushWorkItem?.cancel()
                self.emit(burst.summary, endedAt: burst.lastEventAt)
                burst = BurstState(
                    summary: BurstSummary(scope: scope, startedAt: now, endedAt: now),
                    lastEventAt: now,
                    flushWorkItem: nil
                )
            }

            update(&burst.summary)
            burst.lastEventAt = now
            burst.summary.endedAt = now
            burst.flushWorkItem?.cancel()
            let flushWorkItem = DispatchWorkItem { [weak self] in
                self?.flush(scope: scope)
            }
            burst.flushWorkItem = flushWorkItem
            self.burstsByScope[scope] = burst
            self.queue.asyncAfter(deadline: .now() + self.quietPeriod, execute: flushWorkItem)
        }
    }

    private func flush(scope: Scope) {
        guard let burst = burstsByScope.removeValue(forKey: scope) else {
            return
        }

        emit(burst.summary, endedAt: burst.lastEventAt)
    }

    private func emit(_ summary: BurstSummary, endedAt: Date) {
        var summary = summary
        summary.endedAt = endedAt
        terminalDiagnosticsLogger.log(
            "burst scope=\(summary.scope.label, privacy: .public) payload=\(Self.logPayload(for: summary), privacy: .public)"
        )

        let onEmit = self.onEmit
        deliverEmission {
            onEmit?(summary)
        }
    }

    func flushForTesting() {
        let pendingBursts: [(summary: BurstSummary, endedAt: Date)] = queue.sync {
            let pendingBursts = burstsByScope.values.map { burst in
                burst.flushWorkItem?.cancel()
                return (summary: burst.summary, endedAt: burst.lastEventAt)
            }
            burstsByScope.removeAll()
            return pendingBursts
        }

        pendingBursts.forEach { burst in
            emit(burst.summary, endedAt: burst.endedAt)
        }
    }

    private var isEnabled: Bool {
        enabledLock.lock()
        defer { enabledLock.unlock() }
        return enabled
    }

    private static func milliseconds(from nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }

    private static var defaultSharedEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["ZENTTY_TERMINAL_DIAGNOSTICS"] == "1"
        #else
        false
        #endif
    }

    private static func rowsBelowViewport(total: UInt64, offset: UInt64, visible: UInt64) -> UInt64 {
        let clampedOffset = min(offset, total)
        let remainingRows = total - clampedOffset
        let visibleRows = min(visible, remainingRows)
        return remainingRows - visibleRows
    }

    private static func metadataChangeKindKey(_ kind: TerminalMetadataChangeKind) -> String {
        switch kind {
        case .noop:
            return "noop"
        case .volatileTitleOnly:
            return "volatileTitleOnly"
        case .meaningful:
            return "meaningful"
        }
    }

    private static func toolKey(_ tool: AgentTool?) -> String {
        switch tool {
        case .claudeCode:
            return "claude"
        case .codex:
            return "codex"
        case .copilot:
            return "copilot"
        case .gemini:
            return "gemini"
        case .openCode:
            return "opencode"
        case .custom(let name):
            return name
        case nil:
            return "unknown"
        }
    }

    private static func actionPayloadKey(for payload: LibghosttySurfaceActionPayload) -> String {
        switch payload {
        case .setTitle:
            return "title"
        case .pwd:
            return "pwd"
        case .progressReport:
            return "progressReport"
        case .commandFinished,
             .desktopNotification,
             .startSearch,
             .endSearch,
             .searchTotal,
             .searchSelected,
             .openURL:
            return "ordered"
        case .scrollbar:
            return "scrollbar"
        case .mouseShape:
            return "mouseShape"
        }
    }

    private static func invalidationKeys(for impacts: WorklaneAuxiliaryInvalidation) -> [String] {
        var keys: [String] = []
        if impacts.contains(.sidebar) { keys.append("sidebar") }
        if impacts.contains(.header) { keys.append("header") }
        if impacts.contains(.canvas) { keys.append("canvas") }
        if impacts.contains(.attention) { keys.append("attention") }
        if impacts.contains(.openWith) { keys.append("openWith") }
        if impacts.contains(.reviewRefresh) { keys.append("reviewRefresh") }
        if impacts.contains(.surfaceActivities) { keys.append("surfaceActivities") }
        return keys
    }

    private static func increment(_ key: String, in dictionary: inout [String: Int]) {
        dictionary[key, default: 0] += 1
    }

    private static func logPayload(for summary: BurstSummary) -> String {
        var components: [String] = [
            "startedAt=\(summary.startedAt.timeIntervalSince1970)",
            "endedAt=\(summary.endedAt.timeIntervalSince1970)",
            "wakeupCount=\(summary.wakeupCount)",
            "wakeupEnqueueCount=\(summary.wakeupEnqueueCount)",
            "tickCount=\(summary.tickCount)",
            "tickTotalMilliseconds=\(summary.tickTotalMilliseconds)",
            "tickMaxMilliseconds=\(summary.tickMaxMilliseconds)",
            "mainQueueDelayTotalMilliseconds=\(summary.mainQueueDelayTotalMilliseconds)",
            "mainQueueDelayMaxMilliseconds=\(summary.mainQueueDelayMaxMilliseconds)",
            "actionCallbackCount=\(summary.actionCallbackCount)",
            "actionDrainCount=\(summary.actionDrainCount)",
            "actionDrainQueueDelayTotalMilliseconds=\(summary.actionDrainQueueDelayTotalMilliseconds)",
            "actionDrainQueueDelayMaxMilliseconds=\(summary.actionDrainQueueDelayMaxMilliseconds)",
            "scrollbarApplyCount=\(summary.scrollbarApplyCount)",
            "scrollbarApplyTotalMilliseconds=\(summary.scrollbarApplyTotalMilliseconds)",
            "scrollbarApplyMaxMilliseconds=\(summary.scrollbarApplyMaxMilliseconds)",
            "scrollHostSyncCount=\(summary.scrollHostSyncCount)",
            "scrollHostSyncTotalMilliseconds=\(summary.scrollHostSyncTotalMilliseconds)",
            "scrollHostSyncMaxMilliseconds=\(summary.scrollHostSyncMaxMilliseconds)",
            "scrollbarGeometryApplyCount=\(summary.scrollbarGeometryApplyCount)",
            "documentHeightChangeCount=\(summary.documentHeightChangeCount)",
            "documentHeightMaxPoints=\(summary.documentHeightMaxPoints)",
            "documentHeightMaxDeltaPoints=\(summary.documentHeightMaxDeltaPoints)",
            "scrollbarBottomAlignedCount=\(summary.scrollbarBottomAlignedCount)",
            "scrollbarOffBottomCount=\(summary.scrollbarOffBottomCount)",
            "scrollbarWasAtBottomCount=\(summary.scrollbarWasAtBottomCount)",
            "scrollbarAutoFollowEligibleCount=\(summary.scrollbarAutoFollowEligibleCount)",
            "scrollbarAutoFollowSuppressedCount=\(summary.scrollbarAutoFollowSuppressedCount)",
            "scrollbarAutoFollowAppliedCount=\(summary.scrollbarAutoFollowAppliedCount)",
            "scrollbarUserScrolledAwayCount=\(summary.scrollbarUserScrolledAwayCount)",
            "scrollbarExplicitSyncAllowedCount=\(summary.scrollbarExplicitSyncAllowedCount)",
            "scrollbarMaxTotalRows=\(summary.scrollbarMaxTotalRows)",
            "scrollbarMaxOffsetRows=\(summary.scrollbarMaxOffsetRows)",
            "scrollbarMaxVisibleRows=\(summary.scrollbarMaxVisibleRows)",
            "replaySuppressionEnterCount=\(summary.replaySuppressionEnterCount)",
            "replaySuppressionExitCount=\(summary.replaySuppressionExitCount)",
            "replaySuppressionTotalMilliseconds=\(summary.replaySuppressionTotalMilliseconds)",
            "occlusionVisibleCount=\(summary.occlusionVisibleCount)",
            "occlusionHiddenCount=\(summary.occlusionHiddenCount)",
            "reflectScrolledClipViewCount=\(summary.reflectScrolledClipViewCount)",
            "scrollToRowActionCount=\(summary.scrollToRowActionCount)",
            "viewportSyncCount=\(summary.viewportSyncCount)",
            "viewportSyncTotalMilliseconds=\(summary.viewportSyncTotalMilliseconds)",
            "viewportSyncMaxMilliseconds=\(summary.viewportSyncMaxMilliseconds)",
            "metadataDeliveryCount=\(summary.metadataDeliveryCount)",
            "storeUpdateCount=\(summary.storeUpdateCount)",
            "storeFastPathCount=\(summary.storeFastPathCount)",
            "titleChangeCount=\(summary.titleChangeCount)",
            "uniqueTitleCount=\(summary.uniqueTitleCount)"
        ]

        if let commandHint = summary.commandHint {
            components.append("commandHint=\(commandHint)")
        }
        if let liveRuntimeCount = summary.liveRuntimeCount {
            components.append("liveRuntimeCount=\(liveRuntimeCount)")
        }
        if let visiblePaneCount = summary.visiblePaneCount {
            components.append("visiblePaneCount=\(visiblePaneCount)")
        }
        if let windowVisible = summary.windowVisible {
            components.append("windowVisible=\(windowVisible)")
        }
        if let windowKey = summary.windowKey {
            components.append("windowKey=\(windowKey)")
        }
        if let firstTitle = summary.firstTitle {
            components.append("firstTitle=\(firstTitle)")
        }
        if let lastTitle = summary.lastTitle {
            components.append("lastTitle=\(lastTitle)")
        }
        if let firstScrollbarPosition = summary.firstScrollbarPosition {
            components.append("firstScrollbarPosition=\(firstScrollbarPosition)")
        }
        if let lastScrollbarPosition = summary.lastScrollbarPosition {
            components.append("lastScrollbarPosition=\(lastScrollbarPosition)")
        }
        if let scrollbarMinOffsetRows = summary.scrollbarMinOffsetRows {
            components.append("scrollbarMinOffsetRows=\(scrollbarMinOffsetRows)")
        }
        if let scrollbarMinVisibleRows = summary.scrollbarMinVisibleRows {
            components.append("scrollbarMinVisibleRows=\(scrollbarMinVisibleRows)")
        }
        if !summary.replaySuppressionReasonCounts.isEmpty {
            components.append("replaySuppressionReasons=\(summary.replaySuppressionReasonCounts)")
        }
        if !summary.metadataChangeKindCounts.isEmpty {
            components.append("metadataChangeKinds=\(summary.metadataChangeKindCounts)")
        }
        if !summary.metadataToolCounts.isEmpty {
            components.append("metadataTools=\(summary.metadataToolCounts)")
        }
        if !summary.actionPayloadCounts.isEmpty {
            components.append("actionPayloads=\(summary.actionPayloadCounts)")
        }
        if !summary.auxiliaryInvalidationCounts.isEmpty {
            components.append("invalidations=\(summary.auxiliaryInvalidationCounts)")
        }
        if !summary.renderCounts.isEmpty {
            components.append("renders=\(summary.renderCounts)")
        }

        return components.joined(separator: " ")
    }

    #if DEBUG
    static func logPayloadForTesting(_ summary: BurstSummary) -> String {
        logPayload(for: summary)
    }
    #endif
}
