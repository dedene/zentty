import AppKit
import QuartzCore

@MainActor
final class SidebarWorklaneRowChrome {
    private enum DropTargetHighlightAnimation {
        static let opacityKey = "dropTargetHighlightOpacity"
        static let fadeDuration: CFTimeInterval = 0.15
    }

    private struct ShadowStyle {
        let color: CGColor
        let opacity: Float
        let radius: CGFloat
        let offset: CGSize
    }

    let tintLayer = CALayer()
    /// Contained drop-target highlight: accent stroke + wash inside the row
    /// bounds, matching the dashed new-worklane placeholder's language. A
    /// shadow glow would bleed past the row edges (shadows draw outside).
    private let dropHighlightLayer = CALayer()
    private var isDropTargetHighlighted = false
    private var normalShadowStyle = ShadowStyle(
        color: NSColor.black.withAlphaComponent(0.02).cgColor,
        opacity: 1,
        radius: 4,
        offset: CGSize(width: 0, height: -1)
    )

    func install(in row: NSButton) {
        row.wantsLayer = true
        row.layer?.cornerRadius = ChromeGeometry.rowRadius
        row.layer?.cornerCurve = .continuous
        row.layer?.masksToBounds = false

        tintLayer.cornerRadius = ChromeGeometry.rowRadius
        tintLayer.cornerCurve = .continuous
        tintLayer.backgroundColor = NSColor.clear.cgColor
        tintLayer.zPosition = -1
        row.layer?.insertSublayer(tintLayer, at: 0)

        dropHighlightLayer.cornerRadius = ChromeGeometry.rowRadius
        dropHighlightLayer.cornerCurve = .continuous
        dropHighlightLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        dropHighlightLayer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
        dropHighlightLayer.borderWidth = 1.5
        dropHighlightLayer.opacity = 0
        dropHighlightLayer.zPosition = -1
        row.layer?.insertSublayer(dropHighlightLayer, at: 1)
    }

    func updateTintFrame(_ bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.frame = bounds
        dropHighlightLayer.frame = bounds
        CATransaction.commit()
    }

    func setDropTargetHighlighted(
        _ highlighted: Bool,
        layer: CALayer?,
        reducedMotion: Bool
    ) {
        guard layer != nil else { return }
        guard highlighted != isDropTargetHighlighted else { return }
        isDropTargetHighlighted = highlighted

        let targetOpacity: Float = highlighted ? 1 : 0

        dropHighlightLayer.removeAnimation(forKey: DropTargetHighlightAnimation.opacityKey)
        let currentOpacity = dropHighlightLayer.presentation()?.opacity ?? dropHighlightLayer.opacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropHighlightLayer.opacity = targetOpacity
        CATransaction.commit()

        guard reducedMotion == false else { return }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = currentOpacity
        fade.toValue = targetOpacity
        fade.duration = DropTargetHighlightAnimation.fadeDuration
        fade.isRemovedOnCompletion = true
        dropHighlightLayer.add(fade, forKey: DropTargetHighlightAnimation.opacityKey)
    }

    func apply(
        summary: WorklaneSidebarSummary,
        theme: ZenttyTheme,
        isWorking: Bool,
        isHovered: Bool,
        isPaneRowHovered: Bool,
        isReorderDragActive: Bool,
        animated: Bool,
        layer: CALayer?
    ) {
        let activeBackground = theme.sidebarButtonActiveBackground
        let hoverBackground = theme.sidebarButtonHoverBackground
        let inactiveBackground = theme.sidebarButtonInactiveBackground
        let activeBorder = theme.sidebarButtonActiveBorder
        let inactiveBorder = theme.sidebarButtonInactiveBorder.withAlphaComponent(
            isHovered ? 0.16 : 0.10
        )
        let normalShadowStyle = ShadowStyle(
            color: NSColor.black.withAlphaComponent(summary.isActive ? 0.08 : 0.02).cgColor,
            opacity: 1,
            radius: summary.isActive ? 12 : 4,
            offset: CGSize(width: 0, height: -1)
        )
        self.normalShadowStyle = normalShadowStyle

        performThemeAnimation(animated: animated) {
            layer?.zPosition = summary.isActive ? 10 : 0
            layer?.backgroundColor =
                SidebarWorklaneRowStyleResolver.resolvedBackgroundColor(
                    isActive: summary.isActive,
                    isWorking: isWorking,
                    isHovered: isHovered,
                    isPaneRowHovered: isPaneRowHovered,
                    isReorderDragActive: isReorderDragActive,
                    activeBackground: activeBackground,
                    hoverBackground: hoverBackground,
                    inactiveBackground: inactiveBackground,
                theme: theme
            ).cgColor
            layer?.borderColor = (summary.isActive ? activeBorder : inactiveBorder).cgColor
            layer?.borderWidth = summary.isActive ? 0.8 : 1
            if let layer {
                self.apply(normalShadowStyle, to: layer)
            }
            self.tintLayer.backgroundColor = SidebarWorklaneRowStyleResolver.tintColor(
                worklaneColor: summary.color,
                isActive: summary.isActive,
                isHovered: isHovered,
                isPaneRowHovered: isPaneRowHovered
            )
        }
    }

    private func apply(_ style: ShadowStyle, to layer: CALayer) {
        layer.shadowColor = style.color
        layer.shadowOpacity = style.opacity
        layer.shadowRadius = style.radius
        layer.shadowOffset = style.offset
    }
}
