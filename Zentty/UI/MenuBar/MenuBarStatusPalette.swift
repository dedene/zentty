import AppKit

/// Curated, menu-native status colors for the dropdown's tinted pills.
///
/// Each ``MenuBarStatusKind`` has explicit light and dark variants, hand-tuned
/// for legibility on the translucent status menu (raw Apple system colors get
/// muddy when contrast-corrected against the real vibrancy material). Two hues
/// per kind: a deep/bright **text** color for the label and leading dot, and a
/// vivid **tint** base for the pill fill and border. Keeping them separate is
/// what keeps the label readable on top of its own fill.
///
/// Colors are resolved concretely from an explicit appearance (the menu forces
/// its appearance, and the pill is layer-backed), so there are no dynamic
/// `NSColor` / `CALayer` resolution surprises. The hex-packing mirrors
/// ``WorklaneColor``.
enum MenuBarStatusPalette {
    /// Pill fill/border opacity over the translucent menu. When the user has
    /// Reduce Transparency on, both push toward opaque so the pill reads without
    /// vibrancy behind it.
    private enum Alpha {
        static let fillLight: CGFloat = 0.15
        static let fillDark: CGFloat = 0.18
        static let borderLight: CGFloat = 0.32
        static let borderDark: CGFloat = 0.34
        static let fillReduced: CGFloat = 0.30
        static let borderReduced: CGFloat = 0.55
    }

    private struct Hex {
        let dark: UInt32
        let light: UInt32
    }

    /// Label + leading-dot color. Deep on light, bright on dark.
    private static func textHex(for kind: MenuBarStatusKind) -> Hex {
        switch kind {
        case .running, .compacting:
            return Hex(dark: 0x46E07E, light: 0x1B8A3E)
        case .needsInput:
            return Hex(dark: 0xFFC24B, light: 0x9A6400)
        case .stoppedEarly:
            return Hex(dark: 0xFF7A6E, light: 0xC5372C)
        case .ready:
            return Hex(dark: 0x5AB0FF, light: 0x0A66D6)
        case .idle:
            return Hex(dark: 0xA4A4AA, light: 0x6B6B70)
        }
    }

    /// Fill + border tint base — the vivid mid hue, lighter than the text color.
    private static func tintHex(for kind: MenuBarStatusKind) -> Hex {
        switch kind {
        case .running, .compacting:
            return Hex(dark: 0x30C864, light: 0x30B450)
        case .needsInput:
            return Hex(dark: 0xFFB428, light: 0xFFAA14)
        case .stoppedEarly:
            return Hex(dark: 0xFF5A50, light: 0xFF463C)
        case .ready:
            return Hex(dark: 0x288CFF, light: 0x007AFF)
        case .idle:
            return Hex(dark: 0x969E9E, light: 0x787880)
        }
    }

    // MARK: - Concrete resolution (single source of truth)

    static func labelColor(for kind: MenuBarStatusKind, isDark: Bool) -> NSColor {
        color(packed(textHex(for: kind), isDark: isDark))
    }

    /// The leading dot matches the label color.
    static func dotColor(for kind: MenuBarStatusKind, isDark: Bool) -> NSColor {
        labelColor(for: kind, isDark: isDark)
    }

    static func fillColor(
        for kind: MenuBarStatusKind,
        isDark: Bool,
        reduceTransparency: Bool
    ) -> NSColor {
        let alpha = reduceTransparency
            ? Alpha.fillReduced
            : (isDark ? Alpha.fillDark : Alpha.fillLight)
        return color(packed(tintHex(for: kind), isDark: isDark), alpha: alpha)
    }

    static func borderColor(
        for kind: MenuBarStatusKind,
        isDark: Bool,
        reduceTransparency: Bool
    ) -> NSColor {
        let alpha = reduceTransparency
            ? Alpha.borderReduced
            : (isDark ? Alpha.borderDark : Alpha.borderLight)
        return color(packed(tintHex(for: kind), isDark: isDark), alpha: alpha)
    }

    /// Whether the given appearance should resolve to the dark variants.
    static func isDark(_ appearance: NSAppearance?) -> Bool {
        appearance?.bestMatch(from: [
            .darkAqua,
            .vibrantDark,
            .accessibilityHighContrastDarkAqua,
            .accessibilityHighContrastVibrantDark,
        ]) != nil
    }

    // MARK: - Helpers

    private static func packed(_ hex: Hex, isDark: Bool) -> UInt32 {
        isDark ? hex.dark : hex.light
    }

    private static func color(_ packed: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((packed >> 16) & 0xFF) / 255.0,
            green: CGFloat((packed >> 8) & 0xFF) / 255.0,
            blue: CGFloat(packed & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}
