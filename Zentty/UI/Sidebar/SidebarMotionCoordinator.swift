import AppKit
import QuartzCore

/// Coordinates sidebar visibility transitions without owning any views or constraints.
///
/// Wraps the existing `SidebarVisibilityController` struct and adds timer-based
/// dismissal logic and motion-state computation. The coordinator notifies its owner
/// (typically `RootViewController`) via the `onMotionStateDidChange` callback so the
/// owner can apply the constraint/animation changes.
@MainActor
final class SidebarMotionCoordinator {

    // MARK: - Public state

    var onMotionStateDidChange: ((SidebarMotionState, Bool) -> Void)?

    var mode: SidebarVisibilityMode {
        sidebarVisibilityController.mode
    }

    var showsResizeHandle: Bool {
        sidebarVisibilityController.showsResizeHandle
    }

    var isFloating: Bool {
        sidebarVisibilityController.isFloating
    }

    var shouldScheduleDismissal: Bool {
        sidebarVisibilityController.shouldScheduleDismissal
    }

    var persistedMode: SidebarVisibilityMode {
        sidebarVisibilityController.persistedMode
    }

    private(set) var currentMotionState: SidebarMotionState

    // MARK: - Sidebar width

    /// The current sidebar width tracked by the coordinator. The coordinator does
    /// not own the width constraint but needs to know the current width for inset
    /// calculations.
    private(set) var currentSidebarWidth: CGFloat

    // MARK: - Private state

    private var sidebarVisibilityController: SidebarVisibilityController
    private var sidebarDismissWorkItem: DispatchWorkItem?
    private let sidebarVisibilityDefaults: UserDefaults
    private let sidebarWidthDefaults: UserDefaults

    // MARK: - Init

    init(
        sidebarVisibilityDefaults: UserDefaults = .standard,
        sidebarWidthDefaults: UserDefaults = .standard
    ) {
        let restoredMode = SidebarVisibilityPreference.restoredVisibility(from: sidebarVisibilityDefaults)
        self.sidebarVisibilityDefaults = sidebarVisibilityDefaults
        self.sidebarWidthDefaults = sidebarWidthDefaults
        self.sidebarVisibilityController = SidebarVisibilityController(mode: restoredMode)
        self.currentMotionState = SidebarMotionState(mode: restoredMode)
        self.currentSidebarWidth = SidebarWidthPreference.restoredWidth(from: sidebarWidthDefaults)
    }

    // MARK: - Event handling

    func handle(_ event: SidebarVisibilityEvent) {
        if event == .togglePressed || event == .hoverRailEntered || event == .sidebarEntered {
            cancelSidebarDismissalTimer()
        }

        let previousMode = sidebarVisibilityController.mode
        sidebarVisibilityController.handle(event)
        let nextMode = sidebarVisibilityController.mode

        if sidebarVisibilityController.shouldScheduleDismissal {
            scheduleSidebarDismissalTimer()
        } else {
            cancelSidebarDismissalTimer()
        }

        guard previousMode != nextMode else {
            return
        }

        SidebarVisibilityPreference.persist(
            sidebarVisibilityController.persistedMode,
            in: sidebarVisibilityDefaults
        )
        let motionState = SidebarMotionState(mode: nextMode)
        currentMotionState = motionState
        onMotionStateDidChange?(motionState, true)
    }

    // MARK: - Sidebar width

    func setSidebarWidth(_ width: CGFloat, persist: Bool) {
        let clampedWidth = SidebarWidthPreference.clamped(width)
        currentSidebarWidth = clampedWidth

        if persist {
            SidebarWidthPreference.persist(clampedWidth, in: sidebarWidthDefaults)
        }
    }

    // MARK: - Inset calculation

    func effectiveLeadingInset(sidebarWidth: CGFloat) -> CGFloat {
        sidebarVisibilityController.effectiveLeadingInset(sidebarWidth: sidebarWidth)
    }

    func effectiveLeadingInset() -> CGFloat {
        effectiveLeadingInset(sidebarWidth: currentSidebarWidth)
    }

    // MARK: - Timers

    private func scheduleSidebarDismissalTimer() {
        cancelSidebarDismissalTimer()
        let workItem = DispatchWorkItem { [weak self] in
            self?.handle(.dismissTimerElapsed)
        }
        sidebarDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SidebarMotionCoordinator.dismissDelay,
            execute: workItem
        )
    }

    private func cancelSidebarDismissalTimer() {
        sidebarDismissWorkItem?.cancel()
        sidebarDismissWorkItem = nil
    }

    // MARK: - Constants

    private static let dismissDelay: TimeInterval = 0.15
}
