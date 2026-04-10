import AppKit

struct LibghosttySelectionAutoscrollTickResult: Equatable {
    let targetRow: Int
    let syntheticMouseLocation: CGPoint
}

final class LibghosttySelectionAutoscrollController {
    struct Configuration: Equatable {
        var topEnterZoneHeight: CGFloat = 36
        var bottomEnterZoneHeight: CGFloat = 36
        var topReleaseZoneHeight: CGFloat = 48
        var bottomReleaseZoneHeight: CGFloat = 48
        var minRowsPerSecond: Double = 5
        var maxRowsPerSecond: Double = 40
        var entryKickRows: Double = 0.35
        var maxBufferedRows: Double = 10
        var rampExponent: Double = 0.85
    }

    private enum EdgeZone {
        case top
        case bottom
    }

    private struct PendingRequest: Equatable {
        let originRow: Int
        let targetRow: Int
        let zone: EdgeZone
    }

    private let configuration: Configuration
    private var viewportHeight: CGFloat = 0
    private var selectionDragActive = false
    private var mouseLocation: CGPoint?
    private var scrollbarUpdate: LibghosttySurfaceScrollbarUpdate?
    private var pendingRequest: PendingRequest?
    private var accumulatedRows: Double = 0
    private var activeEdgeZone: EdgeZone?

    var isWaitingForScrollbarAck: Bool {
        pendingRequest != nil
    }

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    func setViewportHeight(_ height: CGFloat) {
        viewportHeight = max(0, height)
    }

    func setSelectionDragActive(_ active: Bool) {
        selectionDragActive = active
        if !active {
            resetState()
        }
    }

    func setMouseLocation(_ location: CGPoint?) {
        mouseLocation = location
        if location == nil {
            resetState()
        }
    }

    func setScrollbarUpdate(_ update: LibghosttySurfaceScrollbarUpdate?) {
        scrollbarUpdate = update
        guard let update else {
            return
        }

        if let pendingRequest {
            let currentOffset = Int(clamping: update.offset)
            switch pendingRequest.zone {
            case .top:
                if currentOffset < pendingRequest.originRow {
                    self.pendingRequest = nil
                }
            case .bottom:
                if currentOffset > pendingRequest.originRow {
                    self.pendingRequest = nil
                }
            }
        }
    }

    func tick(elapsed: TimeInterval) -> LibghosttySelectionAutoscrollTickResult? {
        guard elapsed > 0,
              selectionDragActive,
              viewportHeight > 0,
              let mouseLocation,
              let scrollbarUpdate,
              let zone = resolvedEdgeZone(for: mouseLocation.y) else {
            return nil
        }

        let currentRow = Int(clamping: scrollbarUpdate.offset)
        let maxRow = max(0, Int(clamping: scrollbarUpdate.total) - Int(clamping: scrollbarUpdate.len))
        let proximity = edgeProximity(for: mouseLocation.y, zone: zone)
        let easedProximity = proximity * proximity * (3 - (2 * proximity))
        let rampedProximity = pow(easedProximity, configuration.rampExponent)
        let rowsPerSecond = configuration.minRowsPerSecond +
            (configuration.maxRowsPerSecond - configuration.minRowsPerSecond) * rampedProximity
        if activeEdgeZone != zone {
            accumulatedRows = configuration.entryKickRows
            activeEdgeZone = zone
        }
        accumulatedRows = min(
            configuration.maxBufferedRows,
            accumulatedRows + (rowsPerSecond * elapsed)
        )

        if pendingRequest != nil {
            return nil
        }

        let rowsToMove = Int(floor(accumulatedRows))
        guard rowsToMove > 0 else {
            return nil
        }
        accumulatedRows -= Double(rowsToMove)

        let unclampedTarget = switch zone {
        case .top:
            currentRow - rowsToMove
        case .bottom:
            currentRow + rowsToMove
        }
        let targetRow = min(max(unclampedTarget, 0), maxRow)
        guard targetRow != currentRow else {
            return nil
        }

        pendingRequest = PendingRequest(originRow: currentRow, targetRow: targetRow, zone: zone)
        return LibghosttySelectionAutoscrollTickResult(
            targetRow: targetRow,
            syntheticMouseLocation: syntheticMouseLocation(for: mouseLocation, zone: zone)
        )
    }

    func syntheticMouseLocation() -> CGPoint? {
        guard selectionDragActive,
              viewportHeight > 0,
              let mouseLocation,
              let zone = resolvedEdgeZone(for: mouseLocation.y) else {
            return nil
        }

        return syntheticMouseLocation(for: mouseLocation, zone: zone)
    }

    private func resetState() {
        pendingRequest = nil
        accumulatedRows = 0
        activeEdgeZone = nil
    }

    private func resolvedEdgeZone(for mouseY: CGFloat) -> EdgeZone? {
        if let activeEdgeZone,
           isWithinZone(mouseY, zone: activeEdgeZone, useReleaseZone: true) {
            return activeEdgeZone
        }

        let enteredZone = enteredEdgeZone(for: mouseY)
        if enteredZone == nil {
            accumulatedRows = 0
        }
        activeEdgeZone = enteredZone
        return enteredZone
    }

    private func enteredEdgeZone(for mouseY: CGFloat) -> EdgeZone? {
        let topZoneHeight = effectiveZoneHeight(for: .top, useReleaseZone: false)
        let bottomZoneHeight = effectiveZoneHeight(for: .bottom, useReleaseZone: false)
        guard topZoneHeight > 0 || bottomZoneHeight > 0 else {
            return nil
        }

        let distanceToTop = max(0, viewportHeight - mouseY)
        let distanceToBottom = mouseY
        let inTopZone = topZoneHeight > 0 && distanceToTop <= topZoneHeight
        let inBottomZone = bottomZoneHeight > 0 && distanceToBottom <= bottomZoneHeight

        switch (inTopZone, inBottomZone) {
        case (true, true):
            return distanceToTop <= distanceToBottom ? .top : .bottom
        case (true, false):
            return .top
        case (false, true):
            return .bottom
        case (false, false):
            return nil
        }
    }

    private func isWithinZone(_ mouseY: CGFloat, zone: EdgeZone, useReleaseZone: Bool) -> Bool {
        let zoneHeight = effectiveZoneHeight(for: zone, useReleaseZone: useReleaseZone)
        guard zoneHeight > 0 else {
            return false
        }

        let distance = distanceToEdge(for: mouseY, zone: zone)
        return distance <= zoneHeight
    }

    private func effectiveZoneHeight(for zone: EdgeZone, useReleaseZone: Bool) -> CGFloat {
        let configuredHeight: CGFloat = switch (zone, useReleaseZone) {
        case (.top, false):
            configuration.topEnterZoneHeight
        case (.bottom, false):
            configuration.bottomEnterZoneHeight
        case (.top, true):
            configuration.topReleaseZoneHeight
        case (.bottom, true):
            configuration.bottomReleaseZoneHeight
        }

        return min(configuredHeight, viewportHeight / 2)
    }

    private func distanceToEdge(for mouseY: CGFloat, zone: EdgeZone) -> CGFloat {
        switch zone {
        case .top:
            max(0, viewportHeight - mouseY)
        case .bottom:
            mouseY
        }
    }

    private func edgeProximity(for mouseY: CGFloat, zone: EdgeZone) -> Double {
        let zoneHeight = max(effectiveZoneHeight(for: zone, useReleaseZone: false), 1)
        let rawProgress: CGFloat = switch zone {
        case .top:
            (mouseY - (viewportHeight - zoneHeight)) / zoneHeight
        case .bottom:
            (zoneHeight - mouseY) / zoneHeight
        }

        return Double(min(max(rawProgress, 0), 1))
    }

    private func syntheticMouseLocation(for mouseLocation: CGPoint, zone: EdgeZone) -> CGPoint {
        CGPoint(
            x: mouseLocation.x,
            y: zone == .top ? max(1, viewportHeight - 1) : 1
        )
    }
}
