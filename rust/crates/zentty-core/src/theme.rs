//! Terminal color theme: background, foreground, cursor, selection, and the
//! 16-color ANSI palette (plus the xterm 256-color cube / grayscale ramp and
//! 24-bit RGB passthrough), with an opacity hint.
//!
//! Platform-agnostic (plain sRGB byte tuples) so the renderer and any future
//! frontend can share it. macOS Zentty leans on Ghostty themes; the Rust core
//! has no Ghostty parser yet, so this ships a cohesive dark default plus a
//! couple of presets and resolves [`zentty_terminal`-style] ANSI/RGB colors.

/// An 8-bit sRGB color.
pub type Rgb = (u8, u8, u8);

/// A terminal color to resolve against a theme: an ANSI/xterm index or 24-bit
/// RGB. Mirrors `zentty_terminal::screen::TerminalColor` without a crate
/// dependency, so the renderer maps one to the other.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ThemeTerminalColor {
    Ansi(u8),
    Rgb(u8, u8, u8),
}

/// A complete terminal color theme.
#[derive(Clone, Debug, PartialEq)]
pub struct Theme {
    pub name: &'static str,
    pub background: Rgb,
    pub foreground: Rgb,
    pub cursor: Rgb,
    pub selection: Rgb,
    /// The 16 base ANSI colors (indices 0–15).
    pub ansi: [Rgb; 16],
    /// Window opacity hint (1.0 = opaque). Applied by the frontend.
    pub opacity: f32,
}

impl Theme {
    /// Resolve an xterm 256-color index to RGB using this theme's base 16
    /// colors, the 6×6×6 cube, and the grayscale ramp.
    pub fn ansi_color(&self, index: u8) -> Rgb {
        match index {
            0..=15 => self.ansi[index as usize],
            16..=231 => xterm_cube(index),
            232..=255 => xterm_grayscale(index),
        }
    }

    /// Resolve a terminal color (ANSI index or 24-bit RGB) to RGB.
    pub fn resolve(&self, color: ThemeTerminalColor) -> Rgb {
        match color {
            ThemeTerminalColor::Ansi(index) => self.ansi_color(index),
            ThemeTerminalColor::Rgb(r, g, b) => (r, g, b),
        }
    }
}

/// xterm 6×6×6 color cube for indices 16–231 (channel levels 0,95,135,…,255).
fn xterm_cube(index: u8) -> Rgb {
    let i = index - 16;
    let level = |c: u8| -> u8 {
        if c == 0 { 0 } else { 55 + c * 40 }
    };
    (level(i / 36), level((i % 36) / 6), level(i % 6))
}

/// xterm 24-step grayscale ramp for indices 232–255 (8,18,…,238).
fn xterm_grayscale(index: u8) -> Rgb {
    let v = 8 + (index - 232) * 10;
    (v, v, v)
}

/// The default cohesive dark theme (matches the macOS Zentty look; teal accent
/// cursor). This is the Phase 1–6 palette, now themed.
pub fn default_dark() -> Theme {
    Theme {
        name: "Zentty Dark",
        background: (0x1e, 0x1e, 0x2e),
        foreground: (0xcd, 0xd6, 0xf4),
        cursor: (0x94, 0xe2, 0xd5),
        selection: (0x45, 0x47, 0x5a),
        ansi: [
            (0x45, 0x47, 0x5a),
            (0xf3, 0x8b, 0xa8),
            (0xa6, 0xe3, 0xa1),
            (0xf9, 0xe2, 0xaf),
            (0x89, 0xb4, 0xfa),
            (0xf5, 0xc2, 0xe7),
            (0x94, 0xe2, 0xd5),
            (0xba, 0xc2, 0xde),
            (0x58, 0x5b, 0x70),
            (0xf3, 0x8b, 0xa8),
            (0xa6, 0xe3, 0xa1),
            (0xf9, 0xe2, 0xaf),
            (0x89, 0xb4, 0xfa),
            (0xf5, 0xc2, 0xe7),
            (0x94, 0xe2, 0xd5),
            (0xa6, 0xad, 0xc8),
        ],
        opacity: 1.0,
    }
}

/// Gruvbox-dark preset.
pub fn gruvbox_dark() -> Theme {
    Theme {
        name: "Gruvbox Dark",
        background: (0x28, 0x28, 0x28),
        foreground: (0xeb, 0xdb, 0xb2),
        cursor: (0xeb, 0xdb, 0xb2),
        selection: (0x50, 0x49, 0x45),
        ansi: [
            (0x28, 0x28, 0x28),
            (0xcc, 0x24, 0x1d),
            (0x98, 0x97, 0x1a),
            (0xd7, 0x99, 0x21),
            (0x45, 0x85, 0x88),
            (0xb1, 0x62, 0x86),
            (0x68, 0x9d, 0x6a),
            (0xa8, 0x99, 0x84),
            (0x92, 0x83, 0x74),
            (0xfb, 0x49, 0x34),
            (0xb8, 0xbb, 0x26),
            (0xfa, 0xbd, 0x2f),
            (0x83, 0xa5, 0x98),
            (0xd3, 0x86, 0x9b),
            (0x8e, 0xc0, 0x7c),
            (0xeb, 0xdb, 0xb2),
        ],
        opacity: 1.0,
    }
}

/// Dracula preset.
pub fn dracula() -> Theme {
    Theme {
        name: "Dracula",
        background: (0x28, 0x2a, 0x36),
        foreground: (0xf8, 0xf8, 0xf2),
        cursor: (0xf8, 0xf8, 0xf2),
        selection: (0x44, 0x47, 0x5a),
        ansi: [
            (0x21, 0x22, 0x2c),
            (0xff, 0x55, 0x55),
            (0x50, 0xfa, 0x7b),
            (0xf1, 0xfa, 0x8c),
            (0xbd, 0x93, 0xf9),
            (0xff, 0x79, 0xc6),
            (0x8b, 0xe9, 0xfd),
            (0xf8, 0xf8, 0xf2),
            (0x62, 0x72, 0xa4),
            (0xff, 0x6e, 0x6e),
            (0x69, 0xff, 0x94),
            (0xff, 0xff, 0xa5),
            (0xd6, 0xac, 0xff),
            (0xff, 0x92, 0xdf),
            (0xa4, 0xff, 0xff),
            (0xff, 0xff, 0xff),
        ],
        opacity: 1.0,
    }
}

/// All built-in themes, default first.
pub fn builtin_themes() -> Vec<Theme> {
    vec![default_dark(), gruvbox_dark(), dracula()]
}

/// Look up a built-in theme by case-insensitive name (matches the `name` field
/// or a kebab-case slug, e.g. "gruvbox-dark").
pub fn theme_by_name(name: &str) -> Option<Theme> {
    let needle = name.trim().to_ascii_lowercase();
    builtin_themes().into_iter().find(|theme| {
        theme.name.to_ascii_lowercase() == needle
            || theme.name.to_ascii_lowercase().replace(' ', "-") == needle
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ansi_index_resolves_through_theme_base_colors() {
        let theme = default_dark();
        // Indices 0–15 come from the theme's own palette.
        assert_eq!(theme.ansi_color(0), theme.ansi[0]);
        assert_eq!(theme.ansi_color(1), (0xf3, 0x8b, 0xa8));
        assert_eq!(theme.ansi_color(15), theme.ansi[15]);
        // A different theme yields different base colors for the same index.
        assert_ne!(default_dark().ansi_color(1), gruvbox_dark().ansi_color(1));
    }

    #[test]
    fn ansi_256_cube_and_grayscale_are_theme_independent() {
        let theme = default_dark();
        assert_eq!(theme.ansi_color(16), (0, 0, 0));
        assert_eq!(theme.ansi_color(196), (255, 0, 0));
        assert_eq!(theme.ansi_color(231), (255, 255, 255));
        assert_eq!(theme.ansi_color(232), (8, 8, 8));
        assert_eq!(theme.ansi_color(255), (238, 238, 238));
        // Cube/grayscale do not depend on the theme.
        assert_eq!(gruvbox_dark().ansi_color(196), (255, 0, 0));
    }

    #[test]
    fn resolve_rgb_passes_through_and_ansi_dispatches() {
        let theme = default_dark();
        assert_eq!(theme.resolve(ThemeTerminalColor::Rgb(10, 20, 30)), (10, 20, 30));
        assert_eq!(theme.resolve(ThemeTerminalColor::Ansi(196)), (255, 0, 0));
    }

    #[test]
    fn theme_by_name_matches_name_and_slug() {
        assert_eq!(theme_by_name("Gruvbox Dark").unwrap().name, "Gruvbox Dark");
        assert_eq!(theme_by_name("gruvbox-dark").unwrap().name, "Gruvbox Dark");
        assert_eq!(theme_by_name("dracula").unwrap().name, "Dracula");
        assert!(theme_by_name("nope").is_none());
    }
}
