import AppKit
import XCTest
@testable import Zentty

final class MenuBarStatusPaletteTests: XCTestCase {
    // (kind, lightTextHex, darkTextHex) — label + dot color.
    private static let textExpectations: [(MenuBarStatusKind, UInt32, UInt32)] = [
        (.running, 0x1B8A3E, 0x46E07E),
        (.compacting, 0x1B8A3E, 0x46E07E),
        (.needsInput, 0x9A6400, 0xFFC24B),
        (.stoppedEarly, 0xC5372C, 0xFF7A6E),
        (.ready, 0x0A66D6, 0x5AB0FF),
        (.idle, 0x6B6B70, 0xA4A4AA),
    ]

    // (kind, lightTintHex, darkTintHex) — fill + border tint base.
    private static let tintExpectations: [(MenuBarStatusKind, UInt32, UInt32)] = [
        (.running, 0x30B450, 0x30C864),
        (.compacting, 0x30B450, 0x30C864),
        (.needsInput, 0xFFAA14, 0xFFB428),
        (.stoppedEarly, 0xFF463C, 0xFF5A50),
        (.ready, 0x007AFF, 0x288CFF),
        (.idle, 0x787880, 0x969E9E),
    ]

    // MARK: - Label / dot color

    func test_label_color_matches_expected_rgb_for_every_kind_and_appearance() {
        for (kind, lightHex, darkHex) in Self.textExpectations {
            assertColor(
                MenuBarStatusPalette.labelColor(for: kind, isDark: false),
                equals: lightHex,
                "\(kind) light label"
            )
            assertColor(
                MenuBarStatusPalette.labelColor(for: kind, isDark: true),
                equals: darkHex,
                "\(kind) dark label"
            )
        }
    }

    func test_dot_color_equals_label_color() {
        for kind in [MenuBarStatusKind.running, .needsInput, .ready] {
            for isDark in [false, true] {
                let dot = MenuBarStatusPalette.dotColor(for: kind, isDark: isDark)
                let label = MenuBarStatusPalette.labelColor(for: kind, isDark: isDark)
                assertSameColor(dot, label, "\(kind) dark=\(isDark) dot vs label")
            }
        }
    }

    // MARK: - Fill / border RGB + alpha

    func test_fill_color_matches_tint_rgb_and_normal_alpha() {
        for (kind, lightHex, darkHex) in Self.tintExpectations {
            assertColor(
                MenuBarStatusPalette.fillColor(for: kind, isDark: false, reduceTransparency: false),
                equals: lightHex,
                alpha: 0.15,
                "\(kind) light fill"
            )
            assertColor(
                MenuBarStatusPalette.fillColor(for: kind, isDark: true, reduceTransparency: false),
                equals: darkHex,
                alpha: 0.18,
                "\(kind) dark fill"
            )
        }
    }

    func test_fill_color_reduce_transparency_uses_opaque_alpha_in_both_modes() {
        for (kind, lightHex, darkHex) in Self.tintExpectations {
            assertColor(
                MenuBarStatusPalette.fillColor(for: kind, isDark: false, reduceTransparency: true),
                equals: lightHex,
                alpha: 0.30,
                "\(kind) light fill reduced"
            )
            assertColor(
                MenuBarStatusPalette.fillColor(for: kind, isDark: true, reduceTransparency: true),
                equals: darkHex,
                alpha: 0.30,
                "\(kind) dark fill reduced"
            )
        }
    }

    func test_border_color_matches_tint_rgb_and_normal_alpha() {
        for (kind, lightHex, darkHex) in Self.tintExpectations {
            assertColor(
                MenuBarStatusPalette.borderColor(for: kind, isDark: false, reduceTransparency: false),
                equals: lightHex,
                alpha: 0.32,
                "\(kind) light border"
            )
            assertColor(
                MenuBarStatusPalette.borderColor(for: kind, isDark: true, reduceTransparency: false),
                equals: darkHex,
                alpha: 0.34,
                "\(kind) dark border"
            )
        }
    }

    func test_border_color_reduce_transparency_uses_opaque_alpha_in_both_modes() {
        for (kind, lightHex, darkHex) in Self.tintExpectations {
            assertColor(
                MenuBarStatusPalette.borderColor(for: kind, isDark: false, reduceTransparency: true),
                equals: lightHex,
                alpha: 0.55,
                "\(kind) light border reduced"
            )
            assertColor(
                MenuBarStatusPalette.borderColor(for: kind, isDark: true, reduceTransparency: true),
                equals: darkHex,
                alpha: 0.55,
                "\(kind) dark border reduced"
            )
        }
    }

    // MARK: - Reduce-transparency monotonicity

    func test_reduce_transparency_raises_fill_and_border_alpha_in_both_modes() {
        let kind = MenuBarStatusKind.running
        for isDark in [false, true] {
            let fillNormal = MenuBarStatusPalette
                .fillColor(for: kind, isDark: isDark, reduceTransparency: false)
                .srgbClamped.alphaComponent
            let fillReduced = MenuBarStatusPalette
                .fillColor(for: kind, isDark: isDark, reduceTransparency: true)
                .srgbClamped.alphaComponent
            XCTAssertGreaterThan(fillReduced, fillNormal, "fill alpha dark=\(isDark)")

            let borderNormal = MenuBarStatusPalette
                .borderColor(for: kind, isDark: isDark, reduceTransparency: false)
                .srgbClamped.alphaComponent
            let borderReduced = MenuBarStatusPalette
                .borderColor(for: kind, isDark: isDark, reduceTransparency: true)
                .srgbClamped.alphaComponent
            XCTAssertGreaterThan(borderReduced, borderNormal, "border alpha dark=\(isDark)")
        }
    }

    // MARK: - isDark

    func test_is_dark_resolves_appearance_variants() {
        XCTAssertTrue(MenuBarStatusPalette.isDark(NSAppearance(named: .darkAqua)))
        XCTAssertFalse(MenuBarStatusPalette.isDark(NSAppearance(named: .aqua)))
        XCTAssertFalse(MenuBarStatusPalette.isDark(nil))
    }

    // MARK: - Helpers

    /// Compares `actual` against a packed `0xRRGGBB` color (and optional alpha)
    /// via their sRGB components, so the assertion is colorspace-stable.
    private func assertColor(
        _ actual: NSColor,
        equals packedHex: UInt32,
        alpha: CGFloat = 1,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = NSColor(
            srgbRed: CGFloat((packedHex >> 16) & 0xFF) / 255.0,
            green: CGFloat((packedHex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(packedHex & 0xFF) / 255.0,
            alpha: alpha
        ).srgbClamped
        let resolved = actual.srgbClamped

        XCTAssertEqual(resolved.redComponent, expected.redComponent, accuracy: 0.001, "\(message) red", file: file, line: line)
        XCTAssertEqual(resolved.greenComponent, expected.greenComponent, accuracy: 0.001, "\(message) green", file: file, line: line)
        XCTAssertEqual(resolved.blueComponent, expected.blueComponent, accuracy: 0.001, "\(message) blue", file: file, line: line)
        XCTAssertEqual(resolved.alphaComponent, expected.alphaComponent, accuracy: 0.001, "\(message) alpha", file: file, line: line)
    }

    private func assertSameColor(
        _ actual: NSColor,
        _ expected: NSColor,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let a = actual.srgbClamped
        let b = expected.srgbClamped
        XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.001, "\(message) red", file: file, line: line)
        XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.001, "\(message) green", file: file, line: line)
        XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.001, "\(message) blue", file: file, line: line)
        XCTAssertEqual(a.alphaComponent, b.alphaComponent, accuracy: 0.001, "\(message) alpha", file: file, line: line)
    }
}
