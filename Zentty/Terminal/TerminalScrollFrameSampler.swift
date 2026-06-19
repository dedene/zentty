import AppKit
import QuartzCore

@MainActor
enum TerminalScrollFramePacingMode: String, Equatable, Sendable {
    case stopped
    case appKitDisplayLink
    case fallbackTimer
}

@MainActor
protocol TerminalScrollFrameSampling: AnyObject {
    var onFrame: (() -> Void)? { get set }
    var pacingMode: TerminalScrollFramePacingMode { get }

    func start(attachedTo view: NSView, preferredFramesPerSecond: Int)
    func stop()
}

@MainActor
protocol TerminalDisplayLinking: AnyObject {
    var preferredFrameRateRange: CAFrameRateRange { get set }

    func add(to runLoop: RunLoop, forMode mode: RunLoop.Mode)
    func invalidate()
}

@MainActor
protocol TerminalDisplayLinkMaking {
    func makeDisplayLink(
        attachedTo view: NSView,
        target: Any,
        selector: Selector
    ) -> (any TerminalDisplayLinking)?
}

@MainActor
final class TerminalScrollFrameSampler: TerminalScrollFrameSampling {
    var onFrame: (() -> Void)?
    private(set) var pacingMode: TerminalScrollFramePacingMode = .stopped

    private let displayLinkMaker: any TerminalDisplayLinkMaking
    private var displayLink: (any TerminalDisplayLinking)?
    private var fallbackTimer: Timer?
    private var isRunning = false

    init() {
        self.displayLinkMaker = AppKitTerminalDisplayLinkMaker()
    }

    init(displayLinkMaker: any TerminalDisplayLinkMaking) {
        self.displayLinkMaker = displayLinkMaker
    }

    func start(attachedTo view: NSView, preferredFramesPerSecond: Int) {
        guard !isRunning else {
            return
        }

        isRunning = true
        let framesPerSecond = Self.clampedFramesPerSecond(preferredFramesPerSecond)
        
        if #available(macOS 14.0, *) {
            if let link = displayLinkMaker.makeDisplayLink(
                attachedTo: view,
                target: self,
                selector: #selector(displayLinkDidFire(_:))
            ) {
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 60,
                    maximum: Float(framesPerSecond),
                    preferred: Float(framesPerSecond)
                )
                link.add(to: .main, forMode: .common)
                displayLink = link
                pacingMode = .appKitDisplayLink
                return
            }
        }


        startFallbackTimer(framesPerSecond: framesPerSecond)
    }

    func stop() {
        guard isRunning || displayLink != nil || fallbackTimer != nil else {
            return
        }

        isRunning = false
        displayLink?.invalidate()
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        pacingMode = .stopped
    }

    deinit {
        MainActorShim.assumeIsolated {
            stop()
        }
    }

    private static func clampedFramesPerSecond(_ preferredFramesPerSecond: Int) -> Int {
        max(60, min(240, preferredFramesPerSecond))
    }

    private func startFallbackTimer(framesPerSecond: Int) {
        let timer = Timer(timeInterval: 1.0 / Double(framesPerSecond), repeats: true) { [weak self] _ in
            guard let self else {
                return
            }

            MainActorShim.assumeIsolated {
                guard self.isRunning else { return }
                self.onFrame?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
        pacingMode = .fallbackTimer
    }

    @available(macOS 14.0, *)
    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        guard isRunning else {
            return
        }

        onFrame?()
    }
}

@MainActor
private final class AppKitTerminalDisplayLinkMaker: TerminalDisplayLinkMaking {
    func makeDisplayLink(
        attachedTo view: NSView,
        target: Any,
        selector: Selector
    ) -> (any TerminalDisplayLinking)? {
        if #available(macOS 14.0, *) {
            return AppKitTerminalDisplayLink(
                displayLink: view.displayLink(target: target, selector: selector)
            )
        } else {
            return nil
        }
    }
}

@available(macOS 14.0, *)
@MainActor
private final class AppKitTerminalDisplayLink: TerminalDisplayLinking {
    var preferredFrameRateRange: CAFrameRateRange {
        get { displayLink.preferredFrameRateRange }
        set { displayLink.preferredFrameRateRange = newValue }
    }

    private let displayLink: CADisplayLink

    init(displayLink: CADisplayLink) {
        self.displayLink = displayLink
    }

    func add(to runLoop: RunLoop, forMode mode: RunLoop.Mode) {
        displayLink.add(to: runLoop, forMode: mode)
    }

    func invalidate() {
        displayLink.invalidate()
    }
}
