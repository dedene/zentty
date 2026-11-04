import AppKit
import XCTest
@testable import Zentty

@MainActor
final class ZenttyThemeTranslucencyTests: XCTestCase {
    private func theme(opacity: CGFloat?, reduceTransparency: Bool = false) -> ZenttyTheme {
        ZenttyTheme(
            resolvedTheme: GhosttyResolvedTheme(
                background: NSColor(hexString: "#0A0C10")!,
                foreground: NSColor(hexString: "#F0F3F6")!,
                cursorColor: NSColor(hexString: "#71B7FF")!,
                selectionBackground: nil,
                selectionForeground: nil,
                palette: [:],
                backgroundOpacity: opacity,
                backgroundBlurRadius: nil
            ),
            reduceTransparency: reduceTransparency
        )
    }

    func test_translucent_theme_has_opaque_backdrop() {
        let translucent = theme(opacity: 0.8)

        XCTAssertTrue(translucent.isTranslucent)
        XCTAssertEqual(translucent.paneOpaqueBackdrop.alphaComponent, 1, accuracy: 0.001)
        XCTAssertEqual(translucent.startupSurface.alphaComponent, 0, accuracy: 0.001)
    }

    func test_opaque_theme_is_not_translucent() {
        XCTAssertFalse(theme(opacity: nil).isTranslucent)
    }

    func test_reduce_transparency_is_not_translucent() {
        let reduced = theme(opacity: 0.8, reduceTransparency: true)

        XCTAssertFalse(reduced.isTranslucent)
        XCTAssertEqual(reduced.paneOpaqueBackdrop.alphaComponent, 1, accuracy: 0.001)
    }

    func test_equality_distinguishes_translucency() {
        XCTAssertNotEqual(theme(opacity: 0.8), theme(opacity: 1))
        XCTAssertEqual(theme(opacity: 0.8), theme(opacity: 0.8))
    }
}
