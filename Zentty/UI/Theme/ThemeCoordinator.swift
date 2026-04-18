import AppKit

/// Resolves and watches Ghostty themes, notifying its owner when the active theme changes.
///
/// `ThemeCoordinator` owns the `GhosttyThemeResolver` and `GhosttyThemeWatcher`.
/// It does NOT apply the theme to views -- that responsibility stays with the owner
/// (typically `RootViewController`) which receives changes via `onThemeDidChange`.
@MainActor
final class ThemeCoordinator {

    // MARK: - Public state

    private(set) var currentTheme: ZenttyTheme

    /// Called when the resolved theme changes. The `Bool` indicates whether the
    /// transition should be animated.
    var onThemeDidChange: ((ZenttyTheme, Bool) -> Void)?

    /// Called when libghostty should rebuild its config. Fires whenever a watched
    /// config file is edited (so non-theme changes like `window-padding-x` are
    /// picked up live) and whenever the resolved theme changes.
    var onTerminalConfigReload: (() -> Void)?

    // MARK: - Private state

    private let themeResolver: GhosttyThemeResolver
    private let themeWatcher: GhosttyThemeWatcher

    // MARK: - Init

    init(
        themeResolver: GhosttyThemeResolver = GhosttyThemeResolver(),
        themeWatcher: GhosttyThemeWatcher = GhosttyThemeWatcher(),
        initialTheme: ZenttyTheme = ZenttyTheme.fallback(for: nil)
    ) {
        self.themeResolver = themeResolver
        self.themeWatcher = themeWatcher
        self.currentTheme = initialTheme

        themeWatcher.onChange = { [weak self] in
            self?.refreshTheme(for: NSApp.effectiveAppearance, animated: true, forceTerminalReload: true)
        }
    }

    // MARK: - Theme resolution

    /// Resolves the theme for the given appearance and notifies the owner if it changed.
    ///
    /// - Parameter forceTerminalReload: Set to `true` when the refresh was triggered
    ///   by a watched config file edit. The user may have changed ghostty settings
    ///   unrelated to the theme (e.g. window-padding-x) that libghostty still needs
    ///   to pick up, so we reload even when the resolved theme is unchanged.
    func refreshTheme(for appearance: NSAppearance, animated: Bool, forceTerminalReload: Bool = false) {
        let resolution = themeResolver.resolve(for: appearance)
        let theme = resolution.map {
            ZenttyTheme(
                resolvedTheme: $0.theme,
                reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            )
        } ?? ZenttyTheme.fallback(
            for: appearance,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )

        let didChange = theme != currentTheme
        currentTheme = theme
        onThemeDidChange?(theme, animated && didChange)
        if didChange || forceTerminalReload {
            onTerminalConfigReload?()
        }
        themeWatcher.watch(urls: resolution?.watchedURLs ?? [themeResolver.configURL])
    }

    /// The config URL used by the resolver, exposed for file-watching setup.
    var configURL: URL {
        themeResolver.configURL
    }
}
