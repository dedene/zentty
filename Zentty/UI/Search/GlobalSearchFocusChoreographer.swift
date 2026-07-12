import AppKit

/// Coordinates the focus dance for global search "find next / previous": it keeps
/// the HUD's search field focused across a pane navigation by holding a
/// preservation token, re-focusing the field on the next runloop turn, and
/// releasing the token shortly after. The exact async hop count (an immediate
/// `DispatchQueue.main.async` refocus plus a 0.3s `DispatchWorkItem` release) is
/// load-bearing and preserved verbatim from the original view-controller code.
@MainActor
final class GlobalSearchFocusChoreographer {
    struct Hooks {
        var isHUDVisible: () -> Bool
        var isFieldFocused: () -> Bool
        var focusField: (Bool) -> Void
        var enterFocusMotion: () -> Void
        var exitFocusMotion: () -> Void
        var endSearchSession: () -> Void
        var focusTerminal: () -> Void
    }

    private let hooks: Hooks
    private var preservationToken: Int?
    private var preservationSequence = 0
    private var releaseWorkItem: DispatchWorkItem?

    init(hooks: Hooks) {
        self.hooks = hooks
    }

    var shouldRetainFocus: Bool {
        preservationToken != nil
            || (hooks.isHUDVisible() && hooks.isFieldFocused())
    }

    func performNavigationPreservingHUD(_ navigation: () -> Void) {
        preservationSequence += 1
        let token = preservationSequence
        preservationToken = token
        releaseWorkItem?.cancel()
        releaseWorkItem = nil

        hooks.enterFocusMotion()

        navigation()
        scheduleNavigationRefocus(token: token)
        scheduleNavigationFocusRelease(token: token)
    }

    private func scheduleNavigationRefocus(token: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.preservationToken == token else { return }

            guard self.hooks.isHUDVisible() else {
                self.preservationToken = nil
                return
            }

            self.hooks.enterFocusMotion()
            self.hooks.focusField(false)
        }
    }

    private func scheduleNavigationFocusRelease(token: Int) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.preservationToken == token else { return }

            self.preservationToken = nil
            self.releaseWorkItem = nil
        }
        releaseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    func closeAndFocusTerminal() {
        preservationToken = nil
        releaseWorkItem?.cancel()
        releaseWorkItem = nil
        hooks.endSearchSession()
        hooks.exitFocusMotion()
        hooks.focusTerminal()
    }

    func handleFocusChanged(_ focused: Bool) {
        if focused {
            hooks.enterFocusMotion()
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.hooks.isFieldFocused() else { return }

            if self.shouldRetainFocus {
                self.hooks.enterFocusMotion()
                self.hooks.focusField(false)
                return
            }

            self.hooks.exitFocusMotion()
        }
    }
}
