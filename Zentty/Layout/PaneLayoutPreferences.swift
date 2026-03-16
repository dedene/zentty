import AppKit
import CoreGraphics

enum DisplayClass: String, CaseIterable, Equatable, Sendable {
    case laptop
    case largeDisplay

    var title: String {
        switch self {
        case .laptop:
            "Laptop"
        case .largeDisplay:
            "Large Display"
        }
    }
}

enum PaneLayoutPreset: String, CaseIterable, Equatable, Sendable {
    case compact
    case balanced
    case roomy

    var title: String {
        switch self {
        case .compact:
            "Compact"
        case .balanced:
            "Balanced"
        case .roomy:
            "Roomy"
        }
    }

    var summary: String {
        switch self {
        case .compact:
            "Tighter new panes with denser multi-pane strips."
        case .balanced:
            "Mid-width new panes for general use."
        case .roomy:
            "Wider new panes with fewer columns on screen."
        }
    }

    func defaultPaneWidth(
        for displayClass: DisplayClass,
        viewportWidth: CGFloat
    ) -> CGFloat {
        let clampedViewportWidth = max(1, viewportWidth)
        let targetRatio: CGFloat

        switch (displayClass, self) {
        case (.laptop, .compact):
            targetRatio = 2 / 3
        case (.laptop, .balanced):
            targetRatio = 3 / 4
        case (.laptop, .roomy):
            targetRatio = 5 / 6
        case (.largeDisplay, .compact):
            targetRatio = 2 / 5
        case (.largeDisplay, .balanced):
            targetRatio = 1 / 2
        case (.largeDisplay, .roomy):
            targetRatio = 3 / 5
        }

        return clampedViewportWidth * targetRatio
    }

    func singlePaneWidth(
        for _: DisplayClass,
        viewportWidth: CGFloat,
        leadingVisibleInset: CGFloat,
        sizing: PaneLayoutSizing
    ) -> CGFloat {
        sizing.readableWidth(
            for: viewportWidth,
            leadingVisibleInset: leadingVisibleInset
        )
    }
}

struct PaneLayoutPreferences: Equatable, Sendable {
    var laptopPreset: PaneLayoutPreset
    var largeDisplayPreset: PaneLayoutPreset

    static let `default` = PaneLayoutPreferences(
        laptopPreset: .compact,
        largeDisplayPreset: .balanced
    )

    func preset(for displayClass: DisplayClass) -> PaneLayoutPreset {
        switch displayClass {
        case .laptop:
            laptopPreset
        case .largeDisplay:
            largeDisplayPreset
        }
    }

    func makeLayoutContext(
        displayClass: DisplayClass,
        viewportWidth: CGFloat,
        leadingVisibleInset: CGFloat,
        sizing: PaneLayoutSizing = .balanced
    ) -> PaneLayoutContext {
        PaneLayoutContext(
            displayClass: displayClass,
            preset: preset(for: displayClass),
            viewportWidth: viewportWidth,
            leadingVisibleInset: leadingVisibleInset,
            sizing: sizing
        )
    }
}

struct PaneLayoutContext: Equatable, Sendable {
    let displayClass: DisplayClass
    let preset: PaneLayoutPreset
    let viewportWidth: CGFloat
    let leadingVisibleInset: CGFloat
    let sizing: PaneLayoutSizing

    var newPaneWidth: CGFloat {
        preset.defaultPaneWidth(
            for: displayClass,
            viewportWidth: viewportWidth
        )
    }

    var singlePaneWidth: CGFloat {
        preset.singlePaneWidth(
            for: displayClass,
            viewportWidth: viewportWidth,
            leadingVisibleInset: leadingVisibleInset,
            sizing: sizing
        )
    }

    static let fallback = PaneLayoutContext(
        displayClass: .largeDisplay,
        preset: .balanced,
        viewportWidth: 1280,
        leadingVisibleInset: 0,
        sizing: .balanced
    )
}

enum PaneDisplayClassResolver {
    private static let threshold: CGFloat = 1440

    static func resolve(screenWidth: CGFloat?, viewportWidth: CGFloat) -> DisplayClass {
        let candidateWidth = screenWidth ?? viewportWidth
        return candidateWidth >= threshold ? .largeDisplay : .laptop
    }

    static func resolve(screen: NSScreen?, viewportWidth: CGFloat) -> DisplayClass {
        resolve(screenWidth: screen?.visibleFrame.width, viewportWidth: viewportWidth)
    }
}

enum PaneLayoutPreferenceStore {
    static let laptopPresetKey = "RootViewController.paneLayout.laptopPreset"
    static let largeDisplayPresetKey = "RootViewController.paneLayout.largeDisplayPreset"

    private static let testDefaultsSuiteName = "ZenttyTests.PaneLayoutPreferenceStore"

    static func restoredPreferences(from defaults: UserDefaults) -> PaneLayoutPreferences {
        PaneLayoutPreferences(
            laptopPreset: restoredPreset(
                from: defaults,
                key: laptopPresetKey,
                fallback: PaneLayoutPreferences.default.laptopPreset
            ),
            largeDisplayPreset: restoredPreset(
                from: defaults,
                key: largeDisplayPresetKey,
                fallback: PaneLayoutPreferences.default.largeDisplayPreset
            )
        )
    }

    static func persist(_ preset: PaneLayoutPreset, for displayClass: DisplayClass, in defaults: UserDefaults) {
        defaults.set(
            preset.rawValue,
            forKey: key(for: displayClass)
        )
    }

    static func userDefaultsForTesting() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: testDefaultsSuiteName) else {
            return .standard
        }

        return defaults
    }

    static func resetForTesting() {
        UserDefaults(suiteName: testDefaultsSuiteName)?
            .removePersistentDomain(forName: testDefaultsSuiteName)
    }

    private static func restoredPreset(
        from defaults: UserDefaults,
        key: String,
        fallback: PaneLayoutPreset
    ) -> PaneLayoutPreset {
        guard let rawValue = defaults.string(forKey: key),
              let preset = PaneLayoutPreset(rawValue: rawValue) else {
            return fallback
        }

        return preset
    }

    private static func key(for displayClass: DisplayClass) -> String {
        switch displayClass {
        case .laptop:
            laptopPresetKey
        case .largeDisplay:
            largeDisplayPresetKey
        }
    }
}
