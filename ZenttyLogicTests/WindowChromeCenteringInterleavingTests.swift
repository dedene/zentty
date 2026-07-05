import AppKit
import XCTest

@testable import Zentty

/// Reproduction harness for the intermittent "title starts at the window
/// center and writes rightward" misalignment. The static centering math is
/// covered by `WindowChromeViewTests`; these tests replay the *dynamic*
/// interleavings suspected of leaving the row planned against stale lane
/// inputs (sidebar transitions, volatile title ticks, inset rewrites), plus
/// a seeded fuzz sweep over random event orderings.
@MainActor
final class WindowChromeCenteringInterleavingTests: AppKitTestCase {

    // MARK: - Deterministic interleaving replays

    func test_row_stays_centered_when_fast_path_title_lands_during_animated_sidebar_transition() {
        let view = makeChromeView(width: 1440)
        view.render(summary: makeSummary(title: "Ready | zentty"))
        applyInsets(view, visible: 290, controls: 340)
        view.layoutSubtreeIfNeeded()
        assertRowCenteredInLane(view, context: "before transition")

        // Sidebar hide, exactly like RootViewController.applySidebarMotionState.
        view.animateNextRowLayoutForSidebarTransition()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.allowsImplicitAnimation = true
            view.leadingVisibleInset = 0
            view.leadingControlsInset = 130
            view.layoutSubtreeIfNeeded()
        }

        // Volatile agent-title tick lands while the transition is in flight.
        view.setFocusedLabelText("✳ Merge main branch and review data warehouse integration")
        view.layoutSubtreeIfNeeded()

        assertRowCenteredInLane(view, context: "title tick during sidebar-hide animation")
    }

    func test_row_stays_centered_when_title_tick_fires_inside_animation_group() {
        let view = makeChromeView(width: 1440)
        view.render(summary: makeSummary(title: "Ready | zentty"))
        applyInsets(view, visible: 290, controls: 340)
        view.layoutSubtreeIfNeeded()

        view.animateNextRowLayoutForSidebarTransition()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.allowsImplicitAnimation = true
            view.leadingVisibleInset = 0
            view.leadingControlsInset = 130
            view.layoutSubtreeIfNeeded()
            // Tick arrives before the animation group closes.
            view.setFocusedLabelText("✳ Crunched for 1h 42m 57s · 1 shell still running · watching CI")
            view.layoutSubtreeIfNeeded()
        }
        view.layoutSubtreeIfNeeded()

        assertRowCenteredInLane(view, context: "title tick inside animation group")
    }

    func test_row_stays_centered_after_rapid_sidebar_toggle_retarget() {
        let view = makeChromeView(width: 1440)
        view.render(summary: makeSummary(title: "✳ Merge main branch and review data warehouse integration"))
        applyInsets(view, visible: 290, controls: 340)
        view.layoutSubtreeIfNeeded()

        // Hide…
        view.animateNextRowLayoutForSidebarTransition()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.allowsImplicitAnimation = true
            view.leadingVisibleInset = 0
            view.leadingControlsInset = 130
            view.layoutSubtreeIfNeeded()
        }
        // …and immediately show again, retargeting the in-flight animation.
        view.animateNextRowLayoutForSidebarTransition()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.allowsImplicitAnimation = true
            view.leadingVisibleInset = 290
            view.leadingControlsInset = 340
            view.layoutSubtreeIfNeeded()
        }
        view.layoutSubtreeIfNeeded()

        assertRowCenteredInLane(view, context: "rapid hide/show retarget")
    }

    func test_row_recenters_when_controls_inset_is_corrected_after_animated_transition() {
        let view = makeChromeView(width: 1440)
        view.render(summary: makeSummary(title: "✳ Merge main branch and review data warehouse integration"))
        applyInsets(view, visible: 290, controls: 340)
        view.layoutSubtreeIfNeeded()

        view.animateNextRowLayoutForSidebarTransition()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.allowsImplicitAnimation = true
            view.leadingVisibleInset = 0
            view.leadingControlsInset = 130
            view.layoutSubtreeIfNeeded()
        }
        // viewDidLayout re-derives the inset from the live bar frame and can
        // land a slightly different value right after the animated write.
        view.leadingControlsInset = 132
        view.layoutSubtreeIfNeeded()

        assertRowCenteredInLane(view, context: "post-animation inset correction")
    }

    func test_row_stays_centered_when_trailing_controls_appear_mid_transition() {
        let view = makeChromeView(width: 1440)
        view.render(summary: makeSummary(title: "✳ Merge main branch and review data warehouse integration"))
        applyInsets(view, visible: 290, controls: 340)
        view.layoutSubtreeIfNeeded()

        view.animateNextRowLayoutForSidebarTransition()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.allowsImplicitAnimation = true
            view.leadingVisibleInset = 0
            view.leadingControlsInset = 130
            view.render(openWith: WindowChromeOpenWithState(
                title: "Visual Studio Code",
                icon: nil,
                isPrimaryEnabled: true,
                isMenuEnabled: true
            ))
            view.layoutSubtreeIfNeeded()
        }
        view.layoutSubtreeIfNeeded()

        assertRowCenteredInLane(view, context: "openWith control appears mid-transition")
    }

    // MARK: - Phantom-width items

    /// If a row item is planned with width but laid out with zero height,
    /// it reserves centered space while drawing nothing — shoving the
    /// visible title toward the right edge.
    func test_row_items_are_drawable_when_they_occupy_planned_row_width() {
        let view = makeChromeView(width: 1440)
        view.render(summary: makeSummary(
            title: "✳ Merge main branch and review data warehouse integration"
        ))
        applyInsets(view, visible: 290, controls: 340)
        view.layoutSubtreeIfNeeded()

        let phantoms = view.rowContentFramesForTesting.filter {
            $0.width > 0.5 && $0.height < 1
        }
        XCTAssertTrue(
            phantoms.isEmpty,
            "row items occupy width without drawable height (phantom content): \(phantoms)"
        )
        assertRowCenteredInLane(view, context: "crowded summary", visibleOnly: true)
    }

    // MARK: - Seeded fuzz over event orderings

    func test_fuzz_random_event_orderings_keep_row_centered_in_lane() {
        for seed in UInt64(0)..<UInt64(400) {
            var rng = SplitMix64(seed: seed)
            let view = makeChromeView(width: 1440)
            var eventLog: [String] = []

            let eventCount = 6 + Int(rng.next() % 10)
            for _ in 0..<eventCount {
                performRandomEvent(on: view, rng: &rng, log: &eventLog)
            }

            // Settle: plain layout with no animation context.
            view.layoutSubtreeIfNeeded()
            assertRowCenteredInLane(
                view,
                context: "seed \(seed): \(eventLog.joined(separator: " → "))"
            )
        }
    }

    // MARK: - Fuzz events

    private func performRandomEvent(
        on view: WindowChromeView,
        rng: inout SplitMix64,
        log: inout [String]
    ) {
        switch rng.next() % 8 {
        case 0:
            let title = randomTitle(rng: &rng)
            view.render(summary: makeSummary(
                title: title,
                worklaneTitle: rng.next() % 2 == 0 ? "Merge main branch and review data warehouse integration" : nil,
                remoteContext: rng.next() % 4 == 0 ? "ssh: build-box" : nil,
                includeBranch: rng.next() % 10 < 8,
                includePullRequest: rng.next() % 2 == 0,
                chipCount: Int(rng.next() % 3)
            ))
            log.append("render(title: \(title.count) chars)")
        case 1:
            let title = randomTitle(rng: &rng)
            view.setFocusedLabelText(title)
            log.append("fastPathTitle(\(title.count) chars)")
        case 2:
            let inset = CGFloat(rng.next() % 401)
            view.leadingVisibleInset = inset
            log.append("leadingVisibleInset=\(Int(inset))")
        case 3:
            let inset = CGFloat(rng.next() % 401)
            view.leadingControlsInset = inset
            log.append("leadingControlsInset=\(Int(inset))")
        case 4:
            let width = CGFloat(500 + rng.next() % 1300)
            view.setFrameSize(NSSize(width: width, height: WindowChromeView.preferredHeight))
            log.append("resize(width: \(Int(width)))")
        case 5:
            let visible = CGFloat(rng.next() % 401)
            let controls = CGFloat(rng.next() % 401)
            view.animateNextRowLayoutForSidebarTransition()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                view.leadingVisibleInset = visible
                view.leadingControlsInset = controls
                view.layoutSubtreeIfNeeded()
            }
            log.append("animatedTransition(visible: \(Int(visible)), controls: \(Int(controls)))")
        case 6:
            if rng.next() % 2 == 0 {
                view.render(openWith: WindowChromeOpenWithState(
                    title: "Editor", icon: nil, isPrimaryEnabled: true, isMenuEnabled: true
                ))
                log.append("openWith(on)")
            } else {
                view.render(openWith: nil)
                log.append("openWith(off)")
            }
            if rng.next() % 3 == 0 {
                view.render(server: WindowChromeServerState(
                    title: "localhost:3000", icon: nil, isPrimaryEnabled: true, isMenuEnabled: true
                ))
                log.append("server(on)")
            }
        default:
            view.layoutSubtreeIfNeeded()
            log.append("layout")
        }
    }

    private func randomTitle(rng: inout SplitMix64) -> String {
        let words = [
            "✳", "Merge", "main", "branch", "and", "review", "data", "warehouse",
            "integration", "Crunched", "for", "1h", "42m", "watching", "CI",
            "shell", "still", "running", "Ready", "zentty",
        ]
        let count = Int(rng.next() % 12)
        guard count > 0 else {
            return ""
        }
        return (0..<count).map { _ in words[Int(rng.next() % UInt64(words.count))] }.joined(separator: " ")
    }

    // MARK: - Invariant

    /// The oracle matching the observed bug: content laid out flush against
    /// the lane's right half instead of centered. Asserts (1) the row
    /// container tracks the visible lane and (2) content slack is symmetric.
    private func assertRowCenteredInLane(
        _ view: WindowChromeView,
        context: String,
        visibleOnly: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let lane = view.visibleLaneFrame
        guard lane.width > 160, !view.rowFrame.isEmpty else {
            return
        }

        XCTAssertEqual(
            view.rowFrame.minX, lane.minX, accuracy: 0.5,
            "row container origin diverged from lane [\(context)]",
            file: file, line: line
        )
        XCTAssertEqual(
            view.rowFrame.width, lane.width, accuracy: 0.5,
            "row container width diverged from lane [\(context)]",
            file: file, line: line
        )

        // `visibleOnly` measures what the user actually sees: frames without
        // drawable height reserve centered space but render nothing.
        let contentFrames = view.rowContentFramesForTesting
            .filter { !visibleOnly || $0.height >= 1 }
        guard !contentFrames.isEmpty else {
            return
        }

        let contentMinX = contentFrames.map(\.minX).min() ?? 0
        let contentMaxX = contentFrames.map(\.maxX).max() ?? 0
        let leftSlack = contentMinX
        let rightSlack = view.rowFrame.width - contentMaxX

        XCTAssertGreaterThanOrEqual(
            leftSlack, -0.5,
            "content starts before the lane [\(context)]",
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            contentMaxX, view.rowFrame.width + 0.5,
            "content overflows the lane [\(context)]",
            file: file, line: line
        )
        // Tolerance mirrors WindowChromeViewTests: pixel snapping plus the
        // proxy-icon optical shift make perfect symmetry impossible.
        XCTAssertEqual(
            leftSlack, rightSlack, accuracy: 24,
            "content is off-center in the lane (left \(Int(leftSlack)) vs right \(Int(rightSlack))) [\(context)]",
            file: file, line: line
        )
    }

    // MARK: - Fixtures

    private func makeChromeView(width: CGFloat) -> WindowChromeView {
        WindowChromeView(
            frame: NSRect(x: 0, y: 0, width: width, height: WindowChromeView.preferredHeight)
        )
    }

    private func applyInsets(_ view: WindowChromeView, visible: CGFloat, controls: CGFloat) {
        view.leadingVisibleInset = visible
        view.leadingControlsInset = controls
    }

    private func makeSummary(
        title: String?,
        worklaneTitle: String? = nil,
        remoteContext: String? = nil,
        includeBranch: Bool = true,
        includePullRequest: Bool = true,
        chipCount: Int = 0
    ) -> WorklaneChromeSummary {
        let chips: [WorklaneReviewChip] = [
            WorklaneReviewChip(text: "Draft", style: .info),
            WorklaneReviewChip(text: "2 failing", style: .danger),
        ]
        return WorklaneChromeSummary(
            worklaneTitle: worklaneTitle,
            focusedLabel: title,
            remoteContextLabel: remoteContext,
            cwdPath: "/Users/peter/Development/Zenjoy/Nimbu/Rails/worktrees/feature/data-warehouse-export",
            branch: includeBranch ? "feature/data-warehouse-export" : nil,
            branchURL: nil,
            pullRequest: includePullRequest
                ? WorklanePullRequestSummary(
                    number: 1654,
                    url: URL(string: "https://example.com/pr/1654"),
                    state: .open
                )
                : nil,
            reviewChips: Array(chips.prefix(chipCount))
        )
    }
}

/// Deterministic seedable RNG so failing fuzz sequences replay exactly.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
