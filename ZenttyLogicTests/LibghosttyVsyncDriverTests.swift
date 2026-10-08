import AppKit
import XCTest
@testable import Zentty

@MainActor
final class LibghosttyVsyncDriverTests: AppKitTestCase {
    func test_request_before_attach_starts_ticking_once_attached() {
        let view = NSView()
        let sampler = VsyncSamplerSpy()
        let driver = LibghosttyVsyncDriver(view: view, sampler: sampler)

        driver.requestFromRenderer(true)
        drainMainQueue()
        XCTAssertEqual(sampler.startCount, 0)

        var ticks = 0
        driver.attach { ticks += 1 }

        XCTAssertEqual(sampler.startCount, 1)
        XCTAssertTrue(sampler.startedView === view)
        sampler.triggerFrame()
        sampler.triggerFrame()
        XCTAssertEqual(ticks, 2)
    }

    func test_renderer_demand_starts_and_stops_sampler() {
        let sampler = VsyncSamplerSpy()
        let view = NSView()
        let driver = LibghosttyVsyncDriver(view: view, sampler: sampler)
        driver.attach {}

        driver.requestFromRenderer(true)
        drainMainQueue()
        XCTAssertTrue(sampler.isRunning)

        driver.requestFromRenderer(false)
        drainMainQueue()
        XCTAssertFalse(sampler.isRunning)
    }

    func test_back_to_back_requests_coalesce_to_latest_demand() {
        let sampler = VsyncSamplerSpy()
        let view = NSView()
        let driver = LibghosttyVsyncDriver(view: view, sampler: sampler)
        driver.attach {}

        driver.requestFromRenderer(true)
        driver.requestFromRenderer(false)
        drainMainQueue()

        XCTAssertEqual(sampler.startCount, 0)
        XCTAssertFalse(sampler.isRunning)
    }

    func test_requests_from_renderer_thread_reach_main_thread() {
        let sampler = VsyncSamplerSpy()
        let view = NSView()
        let driver = LibghosttyVsyncDriver(view: view, sampler: sampler)
        driver.attach {}

        let requested = expectation(description: "renderer thread requested ticks")
        Thread.detachNewThread {
            driver.requestFromRenderer(true)
            requested.fulfill()
        }
        wait(for: [requested], timeout: 1)
        drainMainQueue()

        XCTAssertTrue(sampler.isRunning)
    }

    func test_invalidate_stops_ticks_and_ignores_later_requests() {
        let sampler = VsyncSamplerSpy()
        let view = NSView()
        let driver = LibghosttyVsyncDriver(view: view, sampler: sampler)
        var ticks = 0
        driver.attach { ticks += 1 }
        driver.requestFromRenderer(true)
        drainMainQueue()
        XCTAssertTrue(sampler.isRunning)

        driver.invalidate()
        XCTAssertFalse(sampler.isRunning)

        driver.requestFromRenderer(true)
        drainMainQueue()
        sampler.triggerFrame()

        XCTAssertFalse(sampler.isRunning)
        XCTAssertEqual(ticks, 0)
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async {
            drained.fulfill()
        }
        wait(for: [drained], timeout: 1)
    }
}

@MainActor
private final class VsyncSamplerSpy: TerminalScrollFrameSampling {
    var onFrame: (() -> Void)?
    private(set) var pacingMode: TerminalScrollFramePacingMode = .stopped
    private(set) var startCount = 0
    private(set) weak var startedView: NSView?

    var isRunning: Bool {
        pacingMode != .stopped
    }

    func start(attachedTo view: NSView, preferredFramesPerSecond: Int) {
        guard !isRunning else {
            return
        }
        startCount += 1
        startedView = view
        pacingMode = .appKitDisplayLink
    }

    func stop() {
        pacingMode = .stopped
    }

    func triggerFrame() {
        guard isRunning else {
            return
        }
        onFrame?()
    }
}
