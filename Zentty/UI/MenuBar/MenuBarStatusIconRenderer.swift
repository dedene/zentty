import AppKit

enum MenuBarAgentIconSource: Equatable, Sendable {
    case bundledAsset
    case generatedFallback
}

enum MenuBarStatusIconRenderer {
    static let statusItemCanvasSide: CGFloat = 18
    static var statusItemSide: CGFloat { statusItemCanvasSide }
    static let markSide: CGFloat = 14
    static let insetDotSide: CGFloat = 8
    static let agentIconSide: CGFloat = 22
    static let statusItemDotOrigin = NSPoint(
        x: statusItemCanvasSide - insetDotSide - 1,
        y: 1
    )
    private static let statusItemCutoutPadding: CGFloat = 2
    private static let agentIconDotSide: CGFloat = 7.5
    private static let agentIconCutoutPadding: CGFloat = 1.5

    /// The menu bar icon only carries a status dot when at least one agent pane
    /// is non-idle. An all-idle (or empty) fleet shows the clean mark; idle status
    /// still surfaces in the dropdown rows.
    static func showsStatusDot(fleetState: MenuBarFleetState, hasAgentPanes: Bool) -> Bool {
        hasAgentPanes && fleetState != .idle
    }

    static func statusImage(
        fleetState: MenuBarFleetState,
        hasAgentPanes: Bool,
        appearance: NSAppearance? = nil
    ) -> NSImage? {
        statusMarkImage(
            clearsDotCutout: showsStatusDot(fleetState: fleetState, hasAgentPanes: hasAgentPanes)
        )
    }

    static func zenttyMarkImage() -> NSImage? {
        if let image = resourceImage(named: "MenuBarAgentIdle") {
            image.isTemplate = true
            return image
        }
        return generatedZenttyMarkImage()
    }

    static func agentIconTemplateImage(for agentTool: AgentTool) -> NSImage? {
        let image = resolvedAgentIconImage(for: agentTool)
        image.size = NSSize(width: agentIconSide, height: agentIconSide)
        image.isTemplate = true
        return image
    }

    static func agentIconImage(
        for agentTool: AgentTool,
        fleetState: MenuBarFleetState,
        appearance: NSAppearance? = nil
    ) -> NSImage? {
        guard let baseImage = agentIconTemplateImage(for: agentTool) else { return nil }
        return badgedImage(
            baseImage: baseImage,
            canvasSide: agentIconSide,
            dotSide: agentIconDotSide,
            dotOrigin: NSPoint(
                x: agentIconSide - agentIconDotSide - 2,
                y: 2
            ),
            cutoutPadding: agentIconCutoutPadding,
            fleetState: fleetState,
            appearance: appearance
        )
    }

    static func agentIconSource(for agentTool: AgentTool) -> MenuBarAgentIconSource {
        guard let name = agentIconResourceName(for: agentTool),
              hasBundledOrSourceCatalogAsset(named: name) else {
            return .generatedFallback
        }
        return .bundledAsset
    }

    static func hasBundledOrSourceCatalogAsset(named name: String) -> Bool {
        resourceImage(named: name) != nil || sourceCatalogAssetExists(named: name)
    }

    static func dotColor(for fleetState: MenuBarFleetState) -> NSColor {
        switch fleetState {
        case .waiting, .stopped:
            return .systemOrange
        case .compacting, .active:
            return .systemGreen
        case .idle:
            return .secondaryLabelColor
        }
    }

    static func statusTextColor(
        for fleetState: MenuBarFleetState,
        appearance: NSAppearance? = nil
    ) -> NSColor {
        let badgeColor = dotColor(for: fleetState)
        guard fleetState != .idle else { return badgeColor }

        return readableStatusTextColor(
            from: badgeColor,
            on: menuTextContrastBackground(for: appearance)
        )
    }

    private static func menuTextContrastBackground(for appearance: NSAppearance?) -> NSColor {
        let appearanceName = appearance?.bestMatch(from: [.aqua, .darkAqua])
        if appearanceName == .darkAqua {
            return NSColor(calibratedWhite: 0.18, alpha: 1)
        }
        return NSColor(calibratedWhite: 0.74, alpha: 1)
    }

    private static func readableStatusTextColor(
        from color: NSColor,
        on background: NSColor,
        minimumContrast: CGFloat = 4.5
    ) -> NSColor {
        let base = color.srgbClamped.withAlphaComponent(1)
        guard base.contrastRatio(against: background) < minimumContrast else {
            return base
        }

        let target = background.isDarkThemeColor ? NSColor.white : NSColor.black
        var low: CGFloat = 0
        var high: CGFloat = 1
        var best = base.ensuringTextContrast(on: background, minimum: minimumContrast)

        for _ in 0..<18 {
            let amount = (low + high) / 2
            let candidate = base.mixed(towards: target, amount: amount).withAlphaComponent(1)
            if candidate.contrastRatio(against: background) >= minimumContrast {
                best = candidate
                high = amount
            } else {
                low = amount
            }
        }

        return best
    }

    private static func menuBarResourceBundles() -> [Bundle] {
        var bundles: [Bundle] = []
        var seen = Set<String>()

        func append(_ bundle: Bundle) {
            let path = bundle.bundlePath
            guard seen.insert(path).inserted else { return }
            bundles.append(bundle)
        }

        append(.main)
        if let appBundle = hostingAppBundle() {
            append(appBundle)
        }
        for bundle in Bundle.allBundles {
            append(bundle)
        }
        return bundles
    }

    private static func hostingAppBundle() -> Bundle? {
        if let bundle = Bundle.allBundles.first(where: { $0.bundleURL.lastPathComponent == "Zentty.app" }) {
            return bundle
        }

        for key in ["BUILT_PRODUCTS_DIR", "TEST_RUNNER_BUILT_PRODUCTS_DIR"] {
            guard let builtProducts = ProcessInfo.processInfo.environment[key] else {
                continue
            }
            let appURL = URL(fileURLWithPath: builtProducts, isDirectory: true)
                .appendingPathComponent("Zentty.app", isDirectory: true)
            if let bundle = Bundle(url: appURL) {
                return bundle
            }
        }

        var url = Bundle(for: MenuBarResourceBundleToken.self).bundleURL
        while !url.path.isEmpty, url.path != "/" {
            if url.pathExtension == "app" {
                return Bundle(url: url)
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func resourceImage(named name: String) -> NSImage? {
        if let image = NSImage(named: name) {
            return image
        }
        for bundle in menuBarResourceBundles() {
            if let image = bundle.image(forResource: NSImage.Name(name)) {
                return image
            }
        }
        return nil
    }

    private static func sourceCatalogAssetExists(named name: String) -> Bool {
        let contentsURL = sourceAssetCatalogURL()
            .appendingPathComponent("\(name).imageset", isDirectory: true)
            .appendingPathComponent("Contents.json", isDirectory: false)
        return FileManager.default.fileExists(atPath: contentsURL.path)
    }

    private static func sourceAssetCatalogURL() -> URL {
        var url = URL(fileURLWithPath: #filePath, isDirectory: false)
        for _ in 0..<4 {
            url.deleteLastPathComponent()
        }
        return url
            .appendingPathComponent("ZenttyResources", isDirectory: true)
            .appendingPathComponent("Assets.xcassets", isDirectory: true)
    }

    private static func statusMarkImage(clearsDotCutout: Bool = false) -> NSImage? {
        guard let template = zenttyMarkImage() else { return nil }

        let canvas = statusItemCanvasSide
        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.lockFocus()

        let markRect = NSRect(
            x: (canvas - markSide) / 2,
            y: (canvas - markSide) / 2,
            width: markSide,
            height: markSide
        )
        template.draw(
            in: markRect,
            from: NSRect(origin: .zero, size: template.size),
            operation: .sourceOver,
            fraction: 1
        )

        if clearsDotCutout {
            let dotRect = NSRect(
                x: statusItemDotOrigin.x,
                y: statusItemDotOrigin.y,
                width: insetDotSide,
                height: insetDotSide
            )
            clearEllipse(in: dotRect.insetBy(dx: -statusItemCutoutPadding, dy: -statusItemCutoutPadding))
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func badgedImage(
        baseImage: NSImage,
        canvasSide: CGFloat,
        dotSide: CGFloat,
        dotOrigin: NSPoint,
        cutoutPadding: CGFloat,
        fleetState: MenuBarFleetState,
        appearance: NSAppearance?
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: canvasSide, height: canvasSide))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: canvasSide, height: canvasSide)
        let iconColor = labelColor(for: appearance)
        tintedTemplateImage(baseImage, color: iconColor).draw(
            in: rect,
            from: NSRect(origin: .zero, size: baseImage.size),
            operation: .sourceOver,
            fraction: 1
        )

        let dotRect = NSRect(
            x: dotOrigin.x,
            y: dotOrigin.y,
            width: dotSide,
            height: dotSide
        )
        clearEllipse(in: dotRect.insetBy(dx: -cutoutPadding, dy: -cutoutPadding))
        dotColor(for: fleetState).setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

#if DEBUG
    static func badgedImageForTesting(
        baseImage: NSImage,
        canvasSide: CGFloat,
        dotSide: CGFloat,
        dotOrigin: NSPoint,
        cutoutPadding: CGFloat,
        fleetState: MenuBarFleetState
    ) -> NSImage {
        badgedImage(
            baseImage: baseImage,
            canvasSide: canvasSide,
            dotSide: dotSide,
            dotOrigin: dotOrigin,
            cutoutPadding: cutoutPadding,
            fleetState: fleetState,
            appearance: nil
        )
    }
#endif

    private static func clearEllipse(in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setBlendMode(.clear)
        context.fillEllipse(in: rect)
        context.restoreGState()
    }

    private static func tintedTemplateImage(_ image: NSImage, color: NSColor) -> NSImage {
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect, from: rect, operation: .sourceOver, fraction: 1)
        color.setFill()
        rect.fill(using: .sourceIn)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }

    private static func labelColor(for appearance: NSAppearance?) -> NSColor {
        guard let appearance else {
            return .labelColor
        }

        var color = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor
        }
        return color
    }

    private static func resolvedAgentIconImage(for agentTool: AgentTool) -> NSImage {
        agentIconResourceImage(for: agentTool) ?? generatedAgentIconImage(for: agentTool)
    }

    private static func agentIconResourceImage(for agentTool: AgentTool) -> NSImage? {
        guard let name = agentIconResourceName(for: agentTool) else { return nil }
        if let image = resourceImage(named: name) {
            image.isTemplate = true
            return image
        }
        return nil
    }

    private static func agentIconResourceName(for agentTool: AgentTool) -> String? {
        switch agentTool {
        case .zentty:
            return "AgentIconZentty"
        case .amp:
            return "AgentIconAmp"
        case .claudeCode:
            return "AgentIconClaudeCode"
        case .codex:
            return "AgentIconCodex"
        case .copilot:
            return "AgentIconCopilot"
        case .cursor:
            return "AgentIconCursor"
        case .droid:
            return "AgentIconDroid"
        case .gemini:
            return "AgentIconGemini"
        case .kimi:
            return "AgentIconKimi"
        case .openCode:
            return "AgentIconOpenCode"
        case .pi:
            return "AgentIconPi"
        case .grok:
            return "AgentIconGrok"
        case .agy:
            return nil
        case .custom:
            return nil
        }
    }

    private static func generatedAgentIconImage(for agentTool: AgentTool) -> NSImage {
        let side: CGFloat = 16
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()

        NSColor.black.setStroke()
        let path = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 13, height: 13), xRadius: 4, yRadius: 4)
        path.lineWidth = 1.7
        path.stroke()

        let label = fallbackLabel(for: agentTool)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            at: NSPoint(x: side / 2 - size.width / 2, y: side / 2 - size.height / 2),
            withAttributes: attributes
        )

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func fallbackLabel(for agentTool: AgentTool) -> String {
        switch agentTool {
        case .custom:
            return "*"
        case .claudeCode:
            return "C"
        case .openCode:
            return "O"
        default:
            return String(agentTool.displayName.prefix(1)).uppercased()
        }
    }

    private static func generatedZenttyMarkImage() -> NSImage {
        let image = NSImage(size: NSSize(width: markSide, height: markSide))
        image.lockFocus()
        NSColor.labelColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2.3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: 3, y: markSide - 2.5))
        path.line(to: NSPoint(x: markSide - 3, y: markSide - 2.5))
        path.line(to: NSPoint(x: 3.5, y: 2.5))
        path.line(to: NSPoint(x: markSide - 2.5, y: 2.5))
        path.stroke()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

private final class MenuBarResourceBundleToken: NSObject {}
