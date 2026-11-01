import AppKit
import SwiftUI

/// The palette's colors, derived from the command palette tokens so both palettes match every
/// Zentty theme (pattern of `CommandPaletteTheme`).
struct AgentHistoryTheme: Equatable {
    let primaryText: Color
    let secondaryText: Color
    let separator: Color
    let selectedBackground: Color
    let hoverBackground: Color
    /// The "Live" badge and the healthy footer dot.
    let live: Color
    /// Amber: footer problems, "Folder gone", warnings.
    let warning: Color
    /// Turn cards, the resume command row, the consent card's source list.
    let cardBackground: Color
    let cardBorder: Color
    /// Behind highlighted matches.
    let highlightBackground: Color
    /// The folder-gone sheet's opaque card, the dim behind it, and its shadow.
    let sheetBackground: Color
    let sheetBackdrop: Color
    let sheetShadow: Color

    init(zenttyTheme: ZenttyTheme) {
        primaryText = Color(nsColor: zenttyTheme.commandPaletteText)
        secondaryText = Color(nsColor: zenttyTheme.commandPaletteSecondaryText)
        separator = Color(nsColor: zenttyTheme.commandPaletteSeparator)
        selectedBackground = Color(nsColor: zenttyTheme.commandPaletteRowSelectedBackground)
        hoverBackground = Color(nsColor: zenttyTheme.commandPaletteRowHoverBackground)
        live = Color(nsColor: zenttyTheme.statusReady)
        warning = Color(nsColor: zenttyTheme.statusNeedsInput)
        cardBackground = Color(nsColor: zenttyTheme.commandPaletteText.withAlphaComponent(0.05))
        cardBorder = Color(nsColor: zenttyTheme.commandPaletteText.withAlphaComponent(0.09))
        highlightBackground = Color(nsColor: zenttyTheme.statusNeedsInput.withAlphaComponent(0.22))
        sheetBackground = Color(nsColor: zenttyTheme.commandPaletteBackground.withAlphaComponent(1))
        sheetBackdrop = Color.black.opacity(0.35)
        sheetShadow = Color(nsColor: zenttyTheme.commandPaletteShadow)
    }
}

/// Turns highlighted text into an `AttributedString` for SwiftUI `Text`.
enum AgentHistoryTextStyler {
    /// Base `font` and `color` everywhere; matches get the theme's highlight background and a
    /// semibold weight. Ranges are clamped to the text; empty (or unmappable) ranges are dropped.
    static func attributed(
        _ text: AgentHistoryHighlightedText,
        theme: AgentHistoryTheme,
        font: Font,
        color: Color
    ) -> AttributedString {
        var attributed = AttributedString(text.text)
        attributed.font = font
        attributed.foregroundColor = color
        let length = (text.text as NSString).length
        for range in text.ranges {
            // Clamp both ends, so a range straddling an edge keeps its visible part and one
            // wholly outside (NSNotFound included) becomes empty.
            let sum = range.location.addingReportingOverflow(max(range.length, 0))
            let upper = sum.overflow ? Int.max : sum.partialValue
            let start = min(max(range.location, 0), length)
            let end = min(max(upper, start), length)
            guard end > start,
                  let stringRange = Range(NSRange(location: start, length: end - start), in: text.text),
                  let attributedRange = Range(stringRange, in: attributed)
            else {
                continue
            }
            attributed[attributedRange].backgroundColor = theme.highlightBackground
            attributed[attributedRange].font = font.weight(.semibold)
        }
        return attributed
    }
}
