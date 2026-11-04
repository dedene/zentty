import AppKit

/// The palette panel's frame for a parent window frame (screen coordinates): 1010 × 580 pt
/// centered, 25 % from the top, shrinking to 90 % of the window with a 760 pt floor. Narrower
/// windows get a compact list-only panel; the consent card is a 640 pt card (D15).
struct AgentHistoryPanelLayout: Equatable {
    enum Mode: Equatable {
        case results
        /// The consent card's preferred height.
        case consent(fittingHeight: CGFloat)
    }

    static let maxWidth: CGFloat = 1010
    static let minWidth: CGFloat = 760
    static let compactMinWidth: CGFloat = 360
    static let wideListWidth: CGFloat = 430
    static let narrowListWidth: CGFloat = 380
    static let wideListThreshold: CGFloat = 900
    static let maxHeight: CGFloat = 580
    static let minHeight: CGFloat = 320
    static let consentWidth: CGFloat = 640
    static let windowMargin: CGFloat = 16

    let frame: NSRect
    /// The result list's width; the whole panel when there is no preview column.
    let listWidth: CGFloat
    let showsPreview: Bool

    /// List only: → / ⌘Y opens the preview full-panel.
    var isCompact: Bool { !showsPreview }

    static func resolve(windowFrame: NSRect, mode: Mode) -> AgentHistoryPanelLayout {
        let windowWidth = windowFrame.width
        let windowHeight = windowFrame.height
        let heightLimit = (0.75 * windowHeight).rounded(.down) - windowMargin

        let width: CGFloat
        let height: CGFloat
        let listWidth: CGFloat
        let showsPreview: Bool
        switch mode {
        case .results:
            if windowWidth - windowMargin >= minWidth {
                width = min(maxWidth, max(minWidth, (0.9 * windowWidth).rounded(.down)), windowWidth - windowMargin)
                listWidth = width >= wideListThreshold ? wideListWidth : narrowListWidth
                showsPreview = true
            } else {
                width = max(compactMinWidth, (0.9 * windowWidth).rounded(.down))
                listWidth = width
                showsPreview = false
            }
            height = max(minHeight, min(maxHeight, heightLimit))
        case .consent(let fittingHeight):
            width = min(consentWidth, windowWidth - 2 * windowMargin)
            height = min(fittingHeight.rounded(.up), max(minHeight, heightLimit))
            listWidth = width
            showsPreview = false
        }

        let origin = NSPoint(
            x: (windowFrame.midX - width / 2).rounded(.down),
            y: (windowFrame.maxY - 0.25 * windowHeight - height).rounded(.down)
        )
        return AgentHistoryPanelLayout(
            frame: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            listWidth: listWidth,
            showsPreview: showsPreview
        )
    }
}
