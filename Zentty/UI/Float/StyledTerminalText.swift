import AppKit

/// Turns terminal text with SGR sequences (`readStyledText`) into an
/// attributed string for small previews (the pill peek). Colors, bold,
/// faint, italic, underline, inverse and strikethrough are kept; every other
/// escape sequence is dropped.
@MainActor
enum StyledTerminalText {
    struct Style: Equatable {
        var font: NSFont
        var foreground: NSColor
        /// Used for inverse text without an explicit background.
        var background: NSColor = .black
        /// 16-color palette; nil uses `StyledTerminalText.defaultPalette`.
        var palette: [NSColor]? = nil
    }

    /// Zentty's default 16-color palette (the seeded Ghostty palette).
    static let defaultPalette: [NSColor] = [
        0x7A828E, 0xFF9492, 0x26CD4D, 0xFFE073, 0x71B7FF, 0xCB9EFF, 0x24EAF7, 0xD9DEE3,
        0x9EA7B3, 0xFFB1AF, 0x4AE168, 0xFFE073, 0x91CBFF, 0xDBB7FF, 0x56D4DD, 0xFFFFFF,
    ].map { color(rgb: $0) }

    /// The last `maxLines` lines that are not blank at the end (a short
    /// prompt at the top of an empty screen still shows).
    static func tail(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, isBlank(last) {
            lines.removeLast()
        }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    static func attributedString(from text: String, style: Style) -> NSAttributedString {
        let output = NSMutableAttributedString()
        var state = SGRState()
        var run = ""
        let scalars = Array(text.unicodeScalars)
        var index = 0

        func flush() {
            guard !run.isEmpty else { return }
            output.append(NSAttributedString(string: run, attributes: state.attributes(style: style)))
            run = ""
        }

        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\u{1B}" else {
                if scalar != "\r" {
                    run.unicodeScalars.append(scalar)
                }
                index += 1
                continue
            }
            flush()
            index += 1
            guard index < scalars.count else { break }
            switch scalars[index] {
            case "[":
                index += 1
                var parameters = ""
                while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) {
                    parameters.unicodeScalars.append(scalars[index])
                    index += 1
                }
                guard index < scalars.count else { break }
                if scalars[index] == "m" {
                    state.apply(parameters: parameters)
                }
                index += 1
            case "]":
                // OSC: skip to BEL or ST.
                index += 1
                while index < scalars.count {
                    if scalars[index] == "\u{07}" {
                        index += 1
                        break
                    }
                    if scalars[index] == "\u{1B}", index + 1 < scalars.count, scalars[index + 1] == "\\" {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                index += 1
            }
        }
        flush()
        return output
    }

    private static func isBlank(_ line: String) -> Bool {
        attributedString(from: line, style: Style(font: .systemFont(ofSize: 1), foreground: .white))
            .string
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
    }

    fileprivate static func color(rgb: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    /// xterm 256-color index → color, using `palette` for 0–15.
    static func color(index: Int, palette: [NSColor]) -> NSColor? {
        switch index {
        case 0..<16:
            return index < palette.count ? palette[index] : nil
        case 16...231:
            let value = index - 16
            let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
            return NSColor(
                srgbRed: levels[value / 36] / 255,
                green: levels[(value / 6) % 6] / 255,
                blue: levels[value % 6] / 255,
                alpha: 1
            )
        case 232...255:
            let level = CGFloat(8 + (index - 232) * 10) / 255
            return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
        default:
            return nil
        }
    }
}

private struct SGRState {
    enum ColorSpec: Equatable {
        case indexed(Int)
        case rgb(Int)
    }

    var bold = false
    var faint = false
    var italic = false
    var underline = false
    var inverse = false
    var strikethrough = false
    var foreground: ColorSpec?
    var background: ColorSpec?

    mutating func apply(parameters: String) {
        let codes = parameters.isEmpty
            ? [0]
            : parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: self = SGRState()
            case 1: bold = true
            case 2: faint = true
            case 3: italic = true
            case 4: underline = true
            case 7: inverse = true
            case 9: strikethrough = true
            case 21, 22: bold = false; faint = false
            case 23: italic = false
            case 24: underline = false
            case 27: inverse = false
            case 29: strikethrough = false
            case 30...37: foreground = .indexed(code - 30)
            case 39: foreground = nil
            case 40...47: background = .indexed(code - 40)
            case 49: background = nil
            case 90...97: foreground = .indexed(code - 90 + 8)
            case 100...107: background = .indexed(code - 100 + 8)
            case 38, 48:
                let (spec, consumed) = Self.extendedColor(codes, from: index + 1)
                if code == 38 { foreground = spec } else { background = spec }
                index += consumed
            default:
                break
            }
            index += 1
        }
    }

    /// `5;n` or `2;r;g;b` after a 38/48. Returns the color and how many
    /// codes it used.
    private static func extendedColor(_ codes: [Int], from index: Int) -> (ColorSpec?, Int) {
        guard index < codes.count else { return (nil, 0) }
        switch codes[index] {
        case 5 where index + 1 < codes.count:
            return (.indexed(codes[index + 1]), 2)
        case 2 where index + 3 < codes.count:
            let rgb = (min(255, max(0, codes[index + 1])) << 16)
                | (min(255, max(0, codes[index + 2])) << 8)
                | min(255, max(0, codes[index + 3]))
            return (.rgb(rgb), 4)
        default:
            return (nil, 1)
        }
    }

    @MainActor
    func attributes(style: StyledTerminalText.Style) -> [NSAttributedString.Key: Any] {
        var font = style.font
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if !traits.isEmpty {
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
            font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }
        var foregroundColor = resolve(foreground, palette: style.palette ?? StyledTerminalText.defaultPalette) ?? style.foreground
        var backgroundColor = resolve(background, palette: style.palette ?? StyledTerminalText.defaultPalette)
        if inverse {
            let swapped = backgroundColor ?? style.background
            backgroundColor = foregroundColor
            foregroundColor = swapped
        }
        if faint {
            foregroundColor = foregroundColor.withAlphaComponent(0.6)
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foregroundColor,
        ]
        if let backgroundColor {
            attributes[.backgroundColor] = backgroundColor
        }
        if underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    @MainActor
    private func resolve(_ spec: ColorSpec?, palette: [NSColor]) -> NSColor? {
        switch spec {
        case .indexed(let index):
            return StyledTerminalText.color(index: index, palette: palette)
        case .rgb(let rgb):
            return StyledTerminalText.color(rgb: rgb)
        case nil:
            return nil
        }
    }
}
