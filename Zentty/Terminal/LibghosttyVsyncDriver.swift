import AppKit
import os

/// Drives libghostty's vsync from an AppKit display link instead of the
/// per-surface CVDisplayLink libghostty would otherwise create.
///
/// CoreVideo stops every running CVDisplayLink from its own display
/// reconfiguration callback on the main thread, and that stop can wait
/// forever for an IO thread that never acknowledges (issue #131,
/// ghostty-org/ghostty#14150). `NSView.displayLink` is backed by
/// QuartzCore's display timer rather than CoreVideo, so it is not on that
/// path. It needs macOS 14; older systems keep libghostty's CVDisplayLink.
///
/// libghostty asks for ticks from its renderer thread via
/// `requestFromRenderer(_:)`, only when its demand changes. The request is
/// coalesced onto the main thread, where the sampler runs while ticks are
/// wanted.
@MainActor
final class LibghosttyVsyncDriver {
    static var isSupported: Bool {
        if #available(macOS 14.0, *) {
            return true
        }
        return false
    }

    private struct PendingRequest {
        var active = false
        var isScheduled = false
    }

    private nonisolated let pendingRequest = OSAllocatedUnfairLock(initialState: PendingRequest())
    private let sampler: any TerminalScrollFrameSampling
    private weak var view: NSView?
    private var tick: (() -> Void)?
    private var isActive = false

    init(
        view: NSView,
        sampler: any TerminalScrollFrameSampling = TerminalScrollFrameSampler()
    ) {
        self.view = view
        self.sampler = sampler
        sampler.onFrame = { [weak self] in
            self?.tick?()
        }
    }

    /// Starts delivering ticks to `tick` whenever libghostty wants them.
    /// Requests that arrived before this are applied now.
    func attach(tick: @escaping () -> Void) {
        self.tick = tick
        apply()
    }

    /// Stops ticks for good. Must be called before the surface is freed.
    func invalidate() {
        tick = nil
        isActive = false
        sampler.stop()
    }

    /// Called on libghostty's renderer thread. Must not block.
    nonisolated func requestFromRenderer(_ active: Bool) {
        let shouldSchedule = pendingRequest.withLock { request in
            request.active = active
            guard !request.isScheduled else {
                return false
            }
            request.isScheduled = true
            return true
        }
        guard shouldSchedule else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            MainActorShim.assumeIsolated {
                self?.drainRequest()
            }
        }
    }

    private func drainRequest() {
        isActive = pendingRequest.withLock { request in
            request.isScheduled = false
            return request.active
        }
        apply()
    }

    private func apply() {
        guard isActive, tick != nil, let view else {
            sampler.stop()
            return
        }

        let framesPerSecond = view.window?.screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond
            ?? 120
        sampler.start(attachedTo: view, preferredFramesPerSecond: framesPerSecond)
    }
}
