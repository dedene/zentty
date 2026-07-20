@testable import Zentty
import XCTest

final class GhosttySeededColorHealerTests: XCTestCase {
    private let historicBlock = """
    background = #0A0C10
    foreground = #F0F3F6
    cursor-color = #71B7FF
    selection-background = #F0F3F6
    selection-foreground = #0A0C10
    palette = 0=#7A828E
    palette = 1=#FF9492
    palette = 2=#26CD4D
    palette = 3=#FFE073
    palette = 4=#71B7FF
    palette = 5=#CB9EFF
    palette = 6=#24EAF7
    palette = 7=#D9DEE3
    palette = 8=#9EA7B3
    palette = 9=#FFB1AF
    palette = 10=#4AE168
    palette = 11=#FFE073
    palette = 12=#91CBFF
    palette = 13=#DBB7FF
    palette = 14=#56D4DD
    palette = 15=#FFFFFF
    """

    private let historicColorKeys = [
        "background = ",
        "foreground = ",
        "cursor-color = ",
        "selection-background = ",
        "selection-foreground = ",
        "palette = ",
    ]

    func test_exactHistoricBlockWithTheme_stripsAllSeededColorLines() throws {
        let content = "theme = GitHub-Dark-Personal\n" + historicBlock + "\n"

        let healed = try XCTUnwrap(GhosttySeededColorHealer.strippingSeededColors(from: content))

        XCTAssertTrue(healed.contains("theme = GitHub-Dark-Personal"))
        for key in historicColorKeys {
            XCTAssertFalse(healed.contains(key), "expected \(key) to be stripped")
        }
    }

    func test_blockWithOneAlteredValue_returnsNilBecauseBlockIsIncomplete() {
        // The block-wide evidence rule: if even one seeded line is missing (here the user
        // re-authored `background`), the block is no longer our fingerprint, so heal nothing.
        let altered = historicBlock.replacingOccurrences(
            of: "background = #0A0C10",
            with: "background = #123456"
        )
        let content = "theme = TokyoNight\n" + altered + "\n"

        XCTAssertNil(GhosttySeededColorHealer.strippingSeededColors(from: content))
    }

    func test_fullBlockPlusUserExtraColors_stripsBlockButKeepsUserLines() throws {
        // Full seeded block present, plus user-added color lines with different values.
        let content = """
        theme = GitHub-Dark-Personal
        \(historicBlock)
        palette = 16=#ABCDEF
        cursor-text = #123456
        """

        let healed = try XCTUnwrap(GhosttySeededColorHealer.strippingSeededColors(from: content))

        // Seeded block gone...
        XCTAssertFalse(healed.contains("background = #0A0C10"))
        XCTAssertFalse(healed.contains("palette = 0=#7A828E"))
        XCTAssertFalse(healed.contains("palette = 15=#FFFFFF"))
        // ...user-authored lines survive.
        XCTAssertTrue(healed.contains("palette = 16=#ABCDEF"))
        XCTAssertTrue(healed.contains("cursor-text = #123456"))
        XCTAssertTrue(healed.contains("theme = GitHub-Dark-Personal"))
    }

    func test_singleCoincidentalHistoricValueLine_returnsNil() {
        // A user who happens to author one line matching a seeded value keeps it.
        let content = """
        theme = Dracula
        palette = 15=#FFFFFF
        """

        XCTAssertNil(GhosttySeededColorHealer.strippingSeededColors(from: content))
    }

    func test_noThemeLine_returnsNil() {
        let content = historicBlock + "\n"

        XCTAssertNil(GhosttySeededColorHealer.strippingSeededColors(from: content))
    }

    func test_userAuthoredColorsWithTheme_returnsNil() {
        let content = """
        theme = Dracula
        background = #FFFFFF
        foreground = #000000
        palette = 0=#101010
        """

        XCTAssertNil(GhosttySeededColorHealer.strippingSeededColors(from: content))
    }

    func test_contentWithoutColors_returnsNil() {
        let content = """
        theme = Dracula
        font-size = 14
        background-opacity = 0.85
        """

        XCTAssertNil(GhosttySeededColorHealer.strippingSeededColors(from: content))
    }

    func test_preservesCommentsUnrelatedLinesAndBackgroundOpacity() throws {
        let content = """
        # My Ghostty config
        theme = GitHub-Dark-Personal
        font-size = 14
        background-opacity = 0.80

        \(historicBlock)
        # trailing comment
        """

        let healed = try XCTUnwrap(GhosttySeededColorHealer.strippingSeededColors(from: content))

        XCTAssertTrue(healed.contains("# My Ghostty config"))
        XCTAssertTrue(healed.contains("# trailing comment"))
        XCTAssertTrue(healed.contains("font-size = 14"))
        XCTAssertTrue(healed.contains("background-opacity = 0.80"))
        XCTAssertTrue(healed.contains("theme = GitHub-Dark-Personal"))
        XCTAssertFalse(healed.contains("background = #0A0C10"))
        XCTAssertFalse(healed.contains("palette = 0=#7A828E"))
    }

    func test_caseInsensitiveHexValueMatch_stripsReCasedSeededBlock() throws {
        let reCasedBlock = historicBlock.lowercased()
        let content = "theme = GitHub-Dark-Personal\n" + reCasedBlock + "\n"

        let healed = try XCTUnwrap(GhosttySeededColorHealer.strippingSeededColors(from: content))

        XCTAssertFalse(healed.contains("background = #0a0c10"))
        XCTAssertFalse(healed.contains("palette = 0=#7a828e"))
        XCTAssertTrue(healed.contains("theme = GitHub-Dark-Personal"))
    }

    func test_preservesTrailingNewlineBehavior() throws {
        let withTrailing = "theme = GitHub-Dark-Personal\n" + historicBlock + "\n"
        let healedWithTrailing = try XCTUnwrap(
            GhosttySeededColorHealer.strippingSeededColors(from: withTrailing)
        )
        XCTAssertTrue(healedWithTrailing.hasSuffix("\n"))

        let withoutTrailing = "theme = GitHub-Dark-Personal\n" + historicBlock
        let healedWithoutTrailing = try XCTUnwrap(
            GhosttySeededColorHealer.strippingSeededColors(from: withoutTrailing)
        )
        XCTAssertFalse(healedWithoutTrailing.hasSuffix("\n"))
    }
}
