import AppKit
import XCTest
@testable import Zentty

final class CommandPaletteBackdropTests: XCTestCase {
    @MainActor
    func test_visibleCommandPaletteBackdrop_consumesHitTesting() {
        let backdrop = CommandPaletteBackdropView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))

        XCTAssertNil(backdrop.hitTest(NSPoint(x: 160, y: 100)))

        backdrop.setVisible(true, animated: false)

        XCTAssertIdentical(backdrop.hitTest(NSPoint(x: 160, y: 100)), backdrop)
        XCTAssertNil(backdrop.hitTest(NSPoint(x: 400, y: 100)))
    }

    func test_commandPaletteBackdrop_derivesFromThemeBackground_dark() {
        let background = NSColor(hexString: "#0A0C10")!
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: background,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 1.0,
                backgroundBlurRadius: 25
            ),
            reduceTransparency: false
        )

        let backdrop = theme.commandPaletteBackdrop.srgbClamped
        XCTAssertGreaterThan(backdrop.alphaComponent, 0.25)
        XCTAssertLessThan(backdrop.alphaComponent, 0.45)
        XCTAssertLessThan(backdrop.perceivedLuminance, background.perceivedLuminance)
    }

    func test_commandPaletteBackdrop_derivesFromThemeBackground_light() {
        let background = NSColor(hexString: "#F7F4EC")!
        let theme = ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: background,
                foreground: NSColor(hexString: "#1E2428")!,
                cursorColor: NSColor(hexString: "#006DAD")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: 1.0,
                backgroundBlurRadius: 25
            ),
            reduceTransparency: false
        )

        let backdrop = theme.commandPaletteBackdrop.srgbClamped
        XCTAssertGreaterThan(backdrop.alphaComponent, 0.20)
        XCTAssertLessThan(backdrop.alphaComponent, 0.40)
        XCTAssertGreaterThan(backdrop.perceivedLuminance, background.perceivedLuminance * backdrop.alphaComponent)
    }

    func test_commandPaletteBackdrop_isStrongerWhenReduceTransparencyEnabled() {
        let resolved = GhosttyResolvedTheme(
            background: NSColor(hexString: "#0A0C10")!,
            foreground: NSColor(hexString: "#F0F3F6")!,
            cursorColor: NSColor(hexString: "#71B7FF")!,
            selectionBackground: nil,
            selectionForeground: nil,
            palette: [:],
            backgroundOpacity: 0.5,
            backgroundBlurRadius: 25
        )

        let normal = ZenttyTheme(resolvedTheme: resolved, reduceTransparency: false)
        let reduced = ZenttyTheme(resolvedTheme: resolved, reduceTransparency: true)

        XCTAssertGreaterThan(
            reduced.commandPaletteBackdrop.srgbClamped.alphaComponent,
            normal.commandPaletteBackdrop.srgbClamped.alphaComponent
        )
    }
}
