import AppKit
import CoreGraphics
import QuartzCore

struct PanePresentation: Equatable, Sendable {
    let paneID: PaneID
    let frame: CGRect
    let emphasis: CGFloat
    let isFocused: Bool
}

struct StripPresentation: Equatable, Sendable {
    let panes: [PanePresentation]
    let contentWidth: CGFloat
    let targetOffset: CGFloat
}

@MainActor
final class PaneStripMotionController {
    private enum Layout {
        static let focusedEmphasis: CGFloat = 1
        static let secondaryEmphasis: CGFloat = 0.92
    }

    func presentation(for state: PaneStripState, in viewportSize: CGSize) -> StripPresentation {
        let layoutItems = state.layoutItems(in: viewportSize)
        let sizing = state.layoutSizing
        let paneHeight = sizing.paneHeight(for: viewportSize.height)

        var cursorX = sizing.horizontalInset
        let presentations = layoutItems.map { item in
            let frame = CGRect(x: cursorX, y: sizing.verticalInset, width: item.width, height: paneHeight)
            cursorX += item.width + sizing.interPaneSpacing
            return PanePresentation(
                paneID: item.pane.id,
                frame: frame,
                emphasis: item.isFocused ? Layout.focusedEmphasis : Layout.secondaryEmphasis,
                isFocused: item.isFocused
            )
        }

        let trailingSpacing = layoutItems.isEmpty ? 0 : sizing.interPaneSpacing
        let contentWidth = max(
            viewportSize.width,
            cursorX - trailingSpacing + sizing.horizontalInset
        )
        let targetOffset = targetOffset(forFocusedPaneIn: presentations, viewportWidth: viewportSize.width, contentWidth: contentWidth)

        return StripPresentation(
            panes: presentations,
            contentWidth: contentWidth,
            targetOffset: targetOffset
        )
    }

    func targetOffset(
        forFocusedPaneIn presentations: [PanePresentation],
        viewportWidth: CGFloat,
        contentWidth: CGFloat
    ) -> CGFloat {
        guard let focusedPane = presentations.first(where: \.isFocused) else {
            return 0
        }

        let unclampedOffset = focusedPane.frame.midX - (viewportWidth / 2)
        return clampedOffset(unclampedOffset, contentWidth: contentWidth, viewportWidth: viewportWidth)
    }

    func clampedOffset(_ proposedOffset: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        let maxOffset = max(0, contentWidth - viewportWidth)
        return min(max(0, proposedOffset), maxOffset)
    }

    func nearestSettlePaneID(
        in presentation: StripPresentation,
        proposedOffset: CGFloat,
        viewportWidth: CGFloat
    ) -> PaneID? {
        guard !presentation.panes.isEmpty else {
            return nil
        }

        let settledOffset = clampedOffset(
            proposedOffset,
            contentWidth: presentation.contentWidth,
            viewportWidth: viewportWidth
        )
        let viewportMidX = settledOffset + (viewportWidth / 2)

        return presentation.panes.min { lhs, rhs in
            abs(lhs.frame.midX - viewportMidX) < abs(rhs.frame.midX - viewportMidX)
        }?.paneID
    }

    func animate(in hostView: NSView, updates: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            updates()
            hostView.layoutSubtreeIfNeeded()
        }
    }
}
