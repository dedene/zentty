import CoreGraphics
import Foundation

/// A timestamped pointer sample taken during a float drag.
struct FloatDragSample: Equatable, Sendable {
    let timestamp: TimeInterval
    let point: CGPoint
}

/// Estimates drag-end velocity (pt/s) from a short rolling window of samples.
/// ``FloatThrowProjection`` reads it to decide a throw to PiP.
struct FloatDragVelocityEstimator: Equatable, Sendable {
    /// Number of most-recent samples retained.
    static let windowSize = 5

    private(set) var samples: [FloatDragSample] = []

    mutating func record(_ sample: FloatDragSample) {
        samples.append(sample)
        if samples.count > Self.windowSize {
            samples.removeFirst(samples.count - Self.windowSize)
        }
    }

    /// Velocity across the retained window (first → last sample), in pt/s.
    /// Zero when there are fewer than two samples or no elapsed time.
    var velocity: CGVector {
        guard let first = samples.first, let last = samples.last else { return .zero }
        let dt = last.timestamp - first.timestamp
        guard dt > 0 else { return .zero }
        return CGVector(
            dx: (last.point.x - first.point.x) / dt,
            dy: (last.point.y - first.point.y) / dt
        )
    }
}

/// Pure, value-type state machine for a float drag. The NSView glue feeds it
/// raw pointer samples (in canvas/layer coordinates) and reads back the
/// transient frame, the drag-end velocity, and whether the gesture was really a
/// click. It never mutates app state — the view decides what to do with the
/// outcome.
struct FloatDragSession: Equatable, Sendable {
    /// Movement (pt) below which a press counts as a click, not a drag.
    static let clickThreshold: CGFloat = 3

    let startMouse: CGPoint
    let startFrame: CGRect
    private(set) var lastMouse: CGPoint
    private var estimator = FloatDragVelocityEstimator()

    init(startMouse: CGPoint, startFrame: CGRect, timestamp: TimeInterval) {
        self.startMouse = startMouse
        self.startFrame = startFrame
        self.lastMouse = startMouse
        estimator.record(FloatDragSample(timestamp: timestamp, point: startMouse))
    }

    mutating func move(to point: CGPoint, timestamp: TimeInterval) {
        lastMouse = point
        estimator.record(FloatDragSample(timestamp: timestamp, point: point))
    }

    /// Pointer translation from drag start to the latest sample.
    var translation: CGVector {
        CGVector(dx: lastMouse.x - startMouse.x, dy: lastMouse.y - startMouse.y)
    }

    /// The frame after applying the transient translation (size unchanged).
    var currentFrame: CGRect {
        CGRect(
            x: startFrame.origin.x + translation.dx,
            y: startFrame.origin.y + translation.dy,
            width: startFrame.width,
            height: startFrame.height
        )
    }

    /// Center of ``currentFrame`` — the point a throw is projected from.
    var currentCenter: CGPoint {
        CGPoint(x: currentFrame.midX, y: currentFrame.midY)
    }

    var velocity: CGVector { estimator.velocity }

    /// True when the pointer never moved meaningfully — a click, not a drag.
    var isClick: Bool {
        hypot(translation.dx, translation.dy) < Self.clickThreshold
    }
}
