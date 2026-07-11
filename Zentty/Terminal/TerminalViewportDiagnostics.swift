import Foundation
import OSLog

enum TerminalViewportLaneRole: String, Equatable, Sendable {
    case activeCanvas
    case peekNeighbor
    case unknown
}

enum TerminalViewportEventSource: String, Equatable, Sendable {
    case activeZoomIn
    case activeZoomInUnsuspend
    case forceViewportSync
    case initialSuspension
    case libghosttySurfaceInit
    case libghosttyUpdateViewport
    case paneContainerFrameSync
    case paneContainerReparent
    case paneContainerSessionActivate
    case paneMounted
    case peekCommit
    case peekNeighborBind
    case peekNeighborCenterOnPane
    case peekNeighborAbandonZoomOut
    case peekNeighborDetach
    case peekNeighborEndZoomOut
    case peekNeighborPrepareZoomOut
    case peekNeighborResetFullCanvas
    case peekOpened
    case peekViewDetach
    case rootPeekDidClose
    case scrollHostLayout
    case scrollHostSync
    case scrollHostSyncSuspended
    case syncAttempt
    case syncSkippedDuplicate
    case syncSkippedNoWindow
    case syncSkippedSuspended
    case syncSkippedZeroBounds
    case syncSuspended
    case syncUnsuspended
}

@MainActor
protocol TerminalViewportDiagnosticsContextConfiguring: AnyObject {
    func updateViewportDiagnosticsContext(_ context: TerminalViewportDiagnostics.Context)
}

final class TerminalViewportDiagnostics: @unchecked Sendable {
    struct Context: Equatable, Sendable {
        var paneID: PaneID?
        var worklaneID: WorklaneID?
        var laneRole: TerminalViewportLaneRole
        var isZoomedOut: Bool?
        var isViewportSyncSuspended: Bool?
        var windowAttached: Bool?
        var containerBounds: CGRect?
        var terminalHostBounds: CGRect?
        var scrollHostBounds: CGRect?
        var surfaceBounds: CGRect?
        var viewportSize: CGSize?
        var previousViewportSize: CGSize?
        var scale: CGFloat?
        var displayID: UInt32?
        var peekSessionID: String?
        var note: String?

        init(
            paneID: PaneID? = nil,
            worklaneID: WorklaneID? = nil,
            laneRole: TerminalViewportLaneRole = .unknown,
            isZoomedOut: Bool? = nil,
            isViewportSyncSuspended: Bool? = nil,
            windowAttached: Bool? = nil,
            containerBounds: CGRect? = nil,
            terminalHostBounds: CGRect? = nil,
            scrollHostBounds: CGRect? = nil,
            surfaceBounds: CGRect? = nil,
            viewportSize: CGSize? = nil,
            previousViewportSize: CGSize? = nil,
            scale: CGFloat? = nil,
            displayID: UInt32? = nil,
            peekSessionID: String? = nil,
            note: String? = nil
        ) {
            self.paneID = paneID
            self.worklaneID = worklaneID
            self.laneRole = laneRole
            self.isZoomedOut = isZoomedOut
            self.isViewportSyncSuspended = isViewportSyncSuspended
            self.windowAttached = windowAttached
            self.containerBounds = containerBounds
            self.terminalHostBounds = terminalHostBounds
            self.scrollHostBounds = scrollHostBounds
            self.surfaceBounds = surfaceBounds
            self.viewportSize = viewportSize
            self.previousViewportSize = previousViewportSize
            self.scale = scale
            self.displayID = displayID
            self.peekSessionID = peekSessionID
            self.note = note
        }
    }

    struct Event: Equatable, Sendable {
        let sequence: Int
        let timestamp: Date
        let source: TerminalViewportEventSource
        let context: Context
    }

    static let shared: TerminalViewportDiagnostics = {
        let diagnostics = TerminalViewportDiagnostics()
        diagnostics.setEnabled(defaultSharedEnabled)
        return diagnostics
    }()

    var onRecord: ((Event) -> Void)?

    private static let logger = Logger(subsystem: "be.zenjoy.zentty", category: "WorklanePeekViewport")
    private let lock = NSLock()
    private let maxEvents: Int
    private var enabled = false
    private var nextSequence = 1
    private var events: [Event] = []

    init(maxEvents: Int = 2_000) {
        self.maxEvents = max(1, maxEvents)
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        lock.unlock()
    }

    func record(_ source: TerminalViewportEventSource, context: Context = Context()) {
        lock.lock()
        guard enabled else {
            lock.unlock()
            return
        }

        let event = Event(
            sequence: nextSequence,
            timestamp: Date(),
            source: source,
            context: context
        )
        nextSequence += 1
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        let onRecord = self.onRecord
        lock.unlock()

        Self.logger.log("\(Self.logPayload(for: event), privacy: .public)")
        onRecord?(event)
    }

    #if DEBUG
    func clearForTesting() {
        lock.lock()
        events.removeAll()
        nextSequence = 1
        lock.unlock()
    }

    func eventsForTesting() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    static func logPayloadForTesting(_ event: Event) -> String {
        logPayload(for: event)
    }
    #endif

    private static var defaultSharedEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["ZENTTY_WORKLANE_PEEK_DIAGNOSTICS"] == "1"
        #else
        false
        #endif
    }

    private static func logPayload(for event: Event) -> String {
        let context = event.context
        var components: [String] = [
            "seq=\(event.sequence)",
            "source=\(event.source.rawValue)",
            "laneRole=\(context.laneRole.rawValue)",
        ]

        if let paneID = context.paneID {
            components.append("paneID=\(paneID.rawValue)")
        }
        if let worklaneID = context.worklaneID {
            components.append("worklaneID=\(worklaneID.rawValue)")
        }
        if let isZoomedOut = context.isZoomedOut {
            components.append("isZoomedOut=\(isZoomedOut)")
        }
        if let isViewportSyncSuspended = context.isViewportSyncSuspended {
            components.append("isViewportSyncSuspended=\(isViewportSyncSuspended)")
        }
        if let windowAttached = context.windowAttached {
            components.append("windowAttached=\(windowAttached)")
        }
        if let containerBounds = context.containerBounds {
            components.append("container=\(format(rect: containerBounds))")
        }
        if let terminalHostBounds = context.terminalHostBounds {
            components.append("terminalHost=\(format(rect: terminalHostBounds))")
        }
        if let scrollHostBounds = context.scrollHostBounds {
            components.append("scrollHost=\(format(rect: scrollHostBounds))")
        }
        if let surfaceBounds = context.surfaceBounds {
            components.append("surface=\(format(rect: surfaceBounds))")
        }
        if let previousViewportSize = context.previousViewportSize {
            components.append("previousViewport=\(format(size: previousViewportSize))")
        }
        if let viewportSize = context.viewportSize {
            components.append("viewport=\(format(size: viewportSize))")
        }
        if let scale = context.scale {
            components.append("scale=\(scale)")
        }
        if let displayID = context.displayID {
            components.append("displayID=\(displayID)")
        }
        if let peekSessionID = context.peekSessionID {
            components.append("peekSessionID=\(peekSessionID)")
        }
        if let note = context.note {
            components.append("note=\(note)")
        }

        return components.joined(separator: " ")
    }

    private static func format(size: CGSize) -> String {
        "\(size.width)x\(size.height)"
    }

    private static func format(rect: CGRect) -> String {
        "\(rect.origin.x),\(rect.origin.y),\(rect.width)x\(rect.height)"
    }
}
