import CoreGraphics
import Foundation

/// Pure two-finger swipe on a PiP. The view feeds it every scroll event that
/// reaches the PiP and acts on the answer; it never touches a view.
///
/// - The PiP follows the fingers with a rubber band (0.35×, capped at 28pt).
/// - Past 70pt on the dominant axis it flicks to the next corner that way,
///   or bounces 14pt when it already sits against that wall. Either ends the
///   swipe: one swipe moves one corner.
/// - Lifting the fingers below the threshold springs it back.
/// - Only touch phases (`began`/`changed`) move it. Momentum never does, and
///   after a flick or bounce the rest of the gesture, momentum included, is
///   captured (`captures`) so it can't scroll whatever ends up under the
///   pointer. A new touch or a 220ms pause ends the capture.
/// - Travel follows the fingers whatever the scroll direction setting
///   (`isDirectionInvertedFromDevice`). Coordinates are y-up.
struct PipSwipeResolver: Equatable, Sendable {
    static let flickDistance: CGFloat = 70
    static let rubberBandFactor: CGFloat = 0.35
    static let rubberBandCap: CGFloat = 28
    static let bounceDistance: CGFloat = 14
    /// A pause this long between events starts over (and ends a capture).
    static let resetGap: TimeInterval = 0.22

    /// `NSEvent.Phase` as a plain value (`none` = no phase, e.g. a mouse wheel).
    enum Phase: Equatable, Sendable {
        case none, mayBegin, began, changed, stationary, ended, cancelled
    }

    struct Event: Equatable, Sendable {
        var phase: Phase
        var momentumPhase: Phase
        /// `scrollingDeltaX/Y` as AppKit reports them.
        var delta: CGVector
        var isDirectionInvertedFromDevice: Bool
        var timestamp: TimeInterval
    }

    enum Action: Equatable, Sendable {
        /// Nothing to show (the event is still the PiP's).
        case none
        /// Draw the PiP this far from its corner.
        case follow(offset: CGVector)
        /// Move to `corner`.
        case flick(to: FloatCorner)
        /// Already against that wall: nudge toward it and back.
        case bounce(toward: CGVector)
        /// Fingers lifted below the threshold: back to the corner.
        case settle
    }

    /// Finger travel of the current swipe (y-up points).
    private(set) var accumulated: CGVector = .zero
    /// A flick or bounce ended this swipe; the rest of it is captured.
    private(set) var isLocked = false
    private var lastTimestamp: TimeInterval?

    mutating func handle(_ event: Event, corner: FloatCorner) -> Action {
        resetAfterPause(event.timestamp)
        if event.momentumPhase != .none {
            endCaptureIfMomentumEnds(event.momentumPhase)
            return .none
        }
        switch event.phase {
        case .began:
            accumulated = .zero
            isLocked = false
            return accumulate(event, corner: corner)
        case .changed:
            guard !isLocked else { return .none }
            return accumulate(event, corner: corner)
        case .ended, .cancelled:
            let springsBack = !isLocked && accumulated != .zero
            accumulated = .zero
            return springsBack ? .settle : .none
        case .none, .mayBegin, .stationary:
            return .none
        }
    }

    /// Whether `event` belongs to a swipe that already flicked or bounced,
    /// wherever the pointer is now. A new touch or a pause ends the capture.
    mutating func captures(_ event: Event) -> Bool {
        resetAfterPause(event.timestamp)
        guard isLocked else { return false }
        if event.phase == .began || event.phase == .mayBegin {
            isLocked = false
            return false
        }
        lastTimestamp = event.timestamp
        endCaptureIfMomentumEnds(event.momentumPhase)
        return true
    }

    // MARK: - Pure helpers

    /// Finger travel (y-up) for a scroll delta. Natural scrolling reports
    /// content motion, which follows the fingers; classic scrolling is the
    /// opposite.
    static func fingerTravel(delta: CGVector, isDirectionInvertedFromDevice: Bool) -> CGVector {
        isDirectionInvertedFromDevice
            ? CGVector(dx: delta.dx, dy: -delta.dy)
            : CGVector(dx: -delta.dx, dy: delta.dy)
    }

    /// 0.35× the travel on each axis, capped at 28pt.
    static func rubberBand(_ travel: CGVector) -> CGVector {
        CGVector(dx: rubberBand(travel.dx), dy: rubberBand(travel.dy))
    }

    /// The neighbour of `corner` in a direction; `corner` itself at a wall.
    /// `positive` is right (horizontal) or up (vertical).
    static func corner(from corner: FloatCorner, horizontal: Bool, positive: Bool) -> FloatCorner {
        var isLeft = corner == .topLeft || corner == .bottomLeft
        var isTop = corner == .topLeft || corner == .topRight
        if horizontal {
            isLeft = !positive
        } else {
            isTop = positive
        }
        switch (isTop, isLeft) {
        case (true, true): return .topLeft
        case (true, false): return .topRight
        case (false, true): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }

    // MARK: - Private

    private mutating func accumulate(_ event: Event, corner: FloatCorner) -> Action {
        let travel = Self.fingerTravel(
            delta: event.delta,
            isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice
        )
        accumulated.dx += travel.dx
        accumulated.dy += travel.dy

        let horizontal = abs(accumulated.dx) > abs(accumulated.dy)
        let magnitude = horizontal ? accumulated.dx : accumulated.dy
        guard abs(magnitude) >= Self.flickDistance else {
            return .follow(offset: Self.rubberBand(accumulated))
        }
        isLocked = true
        accumulated = .zero
        let positive = magnitude > 0
        let next = Self.corner(from: corner, horizontal: horizontal, positive: positive)
        guard next == corner else {
            return .flick(to: next)
        }
        let sign: CGFloat = positive ? 1 : -1
        return .bounce(toward: horizontal
            ? CGVector(dx: sign * Self.bounceDistance, dy: 0)
            : CGVector(dx: 0, dy: sign * Self.bounceDistance))
    }

    private mutating func resetAfterPause(_ timestamp: TimeInterval) {
        if let lastTimestamp, timestamp - lastTimestamp > Self.resetGap {
            accumulated = .zero
            isLocked = false
        }
        lastTimestamp = timestamp
    }

    private mutating func endCaptureIfMomentumEnds(_ momentumPhase: Phase) {
        if momentumPhase == .ended || momentumPhase == .cancelled {
            isLocked = false
        }
    }

    private static func rubberBand(_ value: CGFloat) -> CGFloat {
        let magnitude = min(rubberBandCap, abs(value) * rubberBandFactor)
        return value < 0 ? -magnitude : magnitude
    }
}
