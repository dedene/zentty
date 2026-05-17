import AppKit
import CoreGraphics

enum DisplayClass: String, CaseIterable, Equatable, Sendable {
    case laptop
    case largeDisplay
    case ultrawide

    var title: String {
        switch self {
        case .laptop:
            "Laptop"
        case .largeDisplay:
            "Large Display"
        case .ultrawide:
            "Ultrawide Hybrid"
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
        case (.ultrawide, .compact):
            targetRatio = 2 / 5
        case (.ultrawide, .balanced):
            targetRatio = 1 / 2
        case (.ultrawide, .roomy):
            targetRatio = 3 / 5
        }

        return clampedViewportWidth * targetRatio
    }

    func firstSplitWidth(for displayClass: DisplayClass, viewportWidth: CGFloat) -> CGFloat {
        switch displayClass {
        case .laptop, .largeDisplay:
            defaultPaneWidth(for: displayClass, viewportWidth: viewportWidth)
        case .ultrawide:
            max(1, viewportWidth * 0.5)
        }
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

enum PaneSplitBehaviorMode: String, CaseIterable, Equatable, Sendable {
    case adaptive
    case alwaysSplit
    case alwaysAdd

    var title: String {
        switch self {
        case .adaptive:
            "Adaptive"
        case .alwaysSplit:
            "Always Split"
        case .alwaysAdd:
            "Always Add"
        }
    }
}

enum PaneVisibleSplitWindowWidth: Int, CaseIterable, Equatable, Sendable {
    case px1200 = 1200
    case px1440 = 1440
    case px1680 = 1680
    case px1920 = 1920
    case px2560 = 2560

    var title: String {
        "\(rawValue) pt"
    }

    static func nearest(to value: CGFloat) -> PaneVisibleSplitWindowWidth {
        allCases.min { lhs, rhs in
            abs(CGFloat(lhs.rawValue) - value) < abs(CGFloat(rhs.rawValue) - value)
        } ?? .px1440
    }
}

enum PaneRightInsertionBehavior: Equatable, Sendable {
    case visibleSplit
    case worklaneAdd
}

enum PaneRightCommandPresentation: Equatable, Sendable {
    case splitsVisibly
    case addsToWorklane

    init(behavior: PaneRightInsertionBehavior) {
        switch behavior {
        case .visibleSplit:
            self = .splitsVisibly
        case .worklaneAdd:
            self = .addsToWorklane
        }
    }

    var primaryTitle: String {
        switch self {
        case .splitsVisibly:
            "Split Right"
        case .addsToWorklane:
            "Add Pane Right"
        }
    }

    var primaryDetailDescription: String {
        switch self {
        case .splitsVisibly:
            "Split the current pane area into two visible panes."
        case .addsToWorklane:
            "Add a pane to the right in the worklane without shrinking the current pane."
        }
    }

    var forceOppositeTitle: String {
        switch self {
        case .splitsVisibly:
            "Add Pane Right"
        case .addsToWorklane:
            "Split Right"
        }
    }

    var forceOppositeCommand: PaneCommand {
        switch self {
        case .splitsVisibly:
            .addPaneRightWithoutResizing
        case .addsToWorklane:
            .splitRightVisibly
        }
    }

    var primaryIconSystemName: String {
        switch self {
        case .splitsVisibly:
            "rectangle.split.2x1"
        case .addsToWorklane:
            "arrow.right.square"
        }
    }

    var forceOppositeIconSystemName: String {
        switch self {
        case .splitsVisibly:
            "arrow.right.square"
        case .addsToWorklane:
            "rectangle.split.2x1"
        }
    }
}

struct PaneLayoutPreferences: Equatable, Sendable {
    var laptopPreset: PaneLayoutPreset
    var largeDisplayPreset: PaneLayoutPreset
    var ultrawidePreset: PaneLayoutPreset
    var rightSplitBehaviorMode: PaneSplitBehaviorMode
    var visibleSplitWindowWidth: PaneVisibleSplitWindowWidth

    init(
        laptopPreset: PaneLayoutPreset,
        largeDisplayPreset: PaneLayoutPreset,
        ultrawidePreset: PaneLayoutPreset,
        rightSplitBehaviorMode: PaneSplitBehaviorMode = .adaptive,
        visibleSplitWindowWidth: PaneVisibleSplitWindowWidth = .px1440
    ) {
        self.laptopPreset = laptopPreset
        self.largeDisplayPreset = largeDisplayPreset
        self.ultrawidePreset = ultrawidePreset
        self.rightSplitBehaviorMode = rightSplitBehaviorMode
        self.visibleSplitWindowWidth = visibleSplitWindowWidth
    }

    static let `default` = PaneLayoutPreferences(
        laptopPreset: .compact,
        largeDisplayPreset: .balanced,
        ultrawidePreset: .balanced,
        rightSplitBehaviorMode: .adaptive,
        visibleSplitWindowWidth: .px1440
    )

    func preset(for displayClass: DisplayClass) -> PaneLayoutPreset {
        switch displayClass {
        case .laptop:
            laptopPreset
        case .largeDisplay:
            largeDisplayPreset
        case .ultrawide:
            ultrawidePreset
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
            sizing: sizing,
            rightSplitBehaviorMode: rightSplitBehaviorMode,
            visibleSplitWindowWidth: visibleSplitWindowWidth
        )
    }
}

struct PaneLayoutContext: Equatable, Sendable {
    let displayClass: DisplayClass
    let preset: PaneLayoutPreset
    let viewportWidth: CGFloat
    let leadingVisibleInset: CGFloat
    let sizing: PaneLayoutSizing
    let rightSplitBehaviorMode: PaneSplitBehaviorMode
    let visibleSplitWindowWidth: PaneVisibleSplitWindowWidth

    init(
        displayClass: DisplayClass,
        preset: PaneLayoutPreset,
        viewportWidth: CGFloat,
        leadingVisibleInset: CGFloat,
        sizing: PaneLayoutSizing,
        rightSplitBehaviorMode: PaneSplitBehaviorMode = .adaptive,
        visibleSplitWindowWidth: PaneVisibleSplitWindowWidth = .px1440
    ) {
        self.displayClass = displayClass
        self.preset = preset
        self.viewportWidth = viewportWidth
        self.leadingVisibleInset = leadingVisibleInset
        self.sizing = sizing
        self.rightSplitBehaviorMode = rightSplitBehaviorMode
        self.visibleSplitWindowWidth = visibleSplitWindowWidth
    }

    var availableWidth: CGFloat {
        max(0, viewportWidth - leadingVisibleInset)
    }

    var newPaneWidth: CGFloat {
        preset.defaultPaneWidth(
            for: displayClass,
            viewportWidth: availableWidth
        )
    }

    var shouldResizeFirstPaneOnSingleSplit: Bool {
        displayClass == .ultrawide
    }

    func newPaneWidth(existingPaneCount: Int) -> CGFloat {
        guard existingPaneCount == 1, shouldResizeFirstPaneOnSingleSplit else {
            return newPaneWidth
        }

        return preset.firstSplitWidth(
            for: displayClass,
            viewportWidth: availableWidth - sizing.interPaneSpacing
        )
    }

    var firstPaneWidthAfterSingleSplit: CGFloat? {
        guard shouldResizeFirstPaneOnSingleSplit else {
            return nil
        }

        return preset.firstSplitWidth(
            for: displayClass,
            viewportWidth: availableWidth - sizing.interPaneSpacing
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

    var rightPaneInsertionBehavior: PaneRightInsertionBehavior {
        switch rightSplitBehaviorMode {
        case .adaptive:
            viewportWidth >= CGFloat(visibleSplitWindowWidth.rawValue) ? .visibleSplit : .worklaneAdd
        case .alwaysSplit:
            .visibleSplit
        case .alwaysAdd:
            .worklaneAdd
        }
    }

    var rightPaneCommandPresentation: PaneRightCommandPresentation {
        PaneRightCommandPresentation(behavior: rightPaneInsertionBehavior)
    }

    var visibleSplitColumnWidth: CGFloat {
        max(1, (availableWidth - sizing.interPaneSpacing) / 2)
    }

    static let fallback = PaneLayoutContext(
        displayClass: .largeDisplay,
        preset: .balanced,
        viewportWidth: 1280,
        leadingVisibleInset: 0,
        sizing: .balanced,
        rightSplitBehaviorMode: .adaptive,
        visibleSplitWindowWidth: .px1440
    )
}

enum PaneDisplayClassResolver {
    private static let largeDisplayThreshold: CGFloat = 1440
    private static let ultrawideThreshold: CGFloat = 2560

    static func resolve(screenWidth: CGFloat?, viewportWidth: CGFloat) -> DisplayClass {
        _ = screenWidth
        let candidateWidth = viewportWidth
        if candidateWidth >= ultrawideThreshold {
            return .ultrawide
        }

        if candidateWidth >= largeDisplayThreshold {
            return .largeDisplay
        }

        return .laptop
    }

    static func resolve(screen: NSScreen?, viewportWidth: CGFloat) -> DisplayClass {
        resolve(screenWidth: screen?.visibleFrame.width, viewportWidth: viewportWidth)
    }
}

enum PaneLayoutPreferenceStore {
    static let laptopPresetKey = "RootViewController.paneLayout.laptopPreset"
    static let largeDisplayPresetKey = "RootViewController.paneLayout.largeDisplayPreset"
    static let ultrawidePresetKey = "RootViewController.paneLayout.ultrawidePreset"

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
            ),
            ultrawidePreset: restoredPreset(
                from: defaults,
                key: ultrawidePresetKey,
                fallback: PaneLayoutPreferences.default.ultrawidePreset
            )
        )
    }

    static func persist(_ preset: PaneLayoutPreset, for displayClass: DisplayClass, in defaults: UserDefaults) {
        defaults.set(
            preset.rawValue,
            forKey: key(for: displayClass)
        )
    }

    static func userDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: testDefaultsSuiteName) else {
            return .standard
        }

        return defaults
    }

    static func reset() {
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
        case .ultrawide:
            ultrawidePresetKey
        }
    }
}
