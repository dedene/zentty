import Foundation
import QuartzCore

/// Critically-damped spring driver used by the pane-strip zoom and the visual
/// worklane switcher. Ticks at 120Hz on the main run loop and emits an eased
/// progress value in `[0, 1]`. Callers interpolate their own from/to values.
///
/// The spring is kicked with an initial velocity (`v0`) so it feels snappy
/// without overshoot. Default parameters match the original `PaneStripView`
/// zoom: ω=10, v₀=5, duration=0.35s.
@MainActor
final class SpringAnimator {
    static let defaultDuration: CFTimeInterval = 0.35
    static let defaultOmega: CGFloat = 10
    static let defaultV0: CGFloat = 5

    private var timer: Timer?
    private var startTime: CFTimeInterval = 0
    private var duration: CFTimeInterval = SpringAnimator.defaultDuration
    private var omega: CGFloat = SpringAnimator.defaultOmega
    private var v0: CGFloat = SpringAnimator.defaultV0
    private var onTick: ((CGFloat) -> Void)?
    private var onComplete: (() -> Void)?

    var isRunning: Bool { timer != nil }

    func start(
        duration: CFTimeInterval = SpringAnimator.defaultDuration,
        omega: CGFloat = SpringAnimator.defaultOmega,
        v0: CGFloat = SpringAnimator.defaultV0,
        tick: @escaping (CGFloat) -> Void,
        complete: (() -> Void)? = nil
    ) {
        stop()
        self.duration = duration
        self.omega = omega
        self.v0 = v0
        self.onTick = tick
        self.onComplete = complete
        self.startTime = CACurrentMediaTime()

        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickHandler()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onTick = nil
        onComplete = nil
    }

    private func tickHandler() {
        let elapsed = CACurrentMediaTime() - startTime
        let progress = min(1, elapsed / duration)

        let raw = 1 + ((v0 - omega) * progress - 1) * exp(-omega * progress)
        let norm = 1 + ((v0 - omega) - 1) * exp(-omega)
        let eased = raw / norm

        onTick?(eased)

        if progress >= 1 {
            // Stop the timer BEFORE invoking completion so callers checking
            // `isRunning` from inside the callback see `false` (matches the
            // original PaneStripView contract for `recheckEdgeScroll`).
            let completion = onComplete
            timer?.invalidate()
            timer = nil
            onTick = nil
            onComplete = nil
            completion?()
        }
    }
}
