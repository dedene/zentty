import AppKit
import CoreText

enum SidebarTextMetrics {
    /// Measures the single-line typographic width of `text` rendered in `font`.
    /// Returns 0 for nil or empty strings.
    static func measuredWidth(for text: String?, font: NSFont) -> CGFloat {
        guard let text, text.isEmpty == false else {
            return 0
        }

        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    /// NSTextFieldCell adds a fixed horizontal padding around its contents on
    /// top of the typographic advances reported by CoreText. Constraining a
    /// label to `measuredWidth(...)` clips the glyphs and middle-truncates
    /// short strings like `"main"` to `"m…n"`; callers sizing a label frame
    /// must add this padding.
    static let labelHorizontalPadding: CGFloat = 4

    /// Width an `NSTextField` needs to render `text` without truncation. Use
    /// this when sizing a label frame or width constraint.
    static func labelFittingWidth(for text: String?, font: NSFont) -> CGFloat {
        guard let text, text.isEmpty == false else {
            return 0
        }
        return measuredWidth(for: text, font: font) + labelHorizontalPadding
    }

    /// Measures how many lines `text` would occupy at the given `width` and `lineHeight`.
    /// Returns 1 for empty strings or zero-width containers.
    static func measuredLineCount(
        for text: String,
        font: NSFont,
        lineHeight: CGFloat,
        width: CGFloat
    ) -> Int {
        guard width > 0, text.isEmpty == false else {
            return 1
        }

        let boundingRect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return Int(ceil(boundingRect.height / lineHeight))
    }
}
