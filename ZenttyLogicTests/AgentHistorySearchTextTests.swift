import Foundation
import XCTest
@testable import Zentty

final class AgentHistorySearchTextTests: XCTestCase {
    func test_ascii_fast_path_lowercases_and_collapses_whitespace() {
        XCTAssertEqual(AgentHistorySearchText.normalize("Hello WORLD"), "hello world")
        XCTAssertEqual(AgentHistorySearchText.normalize("a\t\tb\n\nc\r\nd\u{0B}e\u{0C}f"), "a b c d e f")
        XCTAssertEqual(AgentHistorySearchText.normalize("   leading and trailing   "), "leading and trailing")
        XCTAssertEqual(AgentHistorySearchText.normalize("Fix `parseConfig()` in src/App.swift!"), "fix `parseconfig()` in src/app.swift!")
        XCTAssertEqual(AgentHistorySearchText.normalize(""), "")
        XCTAssertEqual(AgentHistorySearchText.normalize(" \n\t "), "")
        XCTAssertEqual(AgentHistorySearchText.normalize("\"quoted\" 'single'"), "\"quoted\" 'single'")
    }

    func test_folds_latin_diacritics() {
        XCTAssertEqual(AgentHistorySearchText.normalize("Café Ñandú"), "cafe nandu")
        XCTAssertEqual(AgentHistorySearchText.normalize("Crème Brûlée"), "creme brulee")
        XCTAssertEqual(AgentHistorySearchText.normalize("Ελληνικά"), "ελληνικα")
        XCTAssertEqual(AgentHistorySearchText.normalize("Ёлка"), "елка")
        XCTAssertEqual(AgentHistorySearchText.normalize("Ứng dụng"), "ung dung")
    }

    func test_keeps_japanese_dakuten_and_hangul() {
        XCTAssertEqual(AgentHistorySearchText.normalize("が"), "が")
        XCTAssertNotEqual(AgentHistorySearchText.normalize("が"), AgentHistorySearchText.normalize("か"))
        XCTAssertEqual(AgentHistorySearchText.normalize("データベース"), "データベース")
        XCTAssertEqual(AgentHistorySearchText.normalize("パスワード"), "パスワード")
        XCTAssertEqual(AgentHistorySearchText.normalize("한국어 검색"), "한국어 검색")
        XCTAssertEqual(AgentHistorySearchText.normalize("中文搜索"), "中文搜索")
    }

    func test_straightens_curly_quotes_and_guillemets() {
        XCTAssertEqual(AgentHistorySearchText.normalize("\u{2018}it\u{2019}s\u{201A}\u{201B}\u{2032}"), "'it's'''")
        XCTAssertEqual(AgentHistorySearchText.normalize("\u{201C}Hi\u{201D} \u{201E}x\u{201F} 5\u{2033}"), "\"hi\" \"x\" 5\"")
        XCTAssertEqual(AgentHistorySearchText.normalize("«Bonjour»"), "\"bonjour\"")
        XCTAssertEqual(
            AgentHistorySearchText.normalize("Don\u{2019}t"),
            AgentHistorySearchText.normalize("Don't")
        )
    }

    func test_nfc_and_nfd_inputs_normalize_identically() {
        let pairs: [(String, String)] = [
            ("Caf\u{00E9}", "Cafe\u{0301}"),
            ("\u{00D1}and\u{00FA}", "N\u{0303}andu\u{0301}"),
            ("\u{304C}", "\u{304B}\u{3099}"),
            ("\u{D55C}\u{AD6D}", "\u{1112}\u{1161}\u{11AB}\u{1100}\u{116E}\u{11A8}"),
            ("\u{1EE8}ng", "U\u{031B}\u{0301}ng"),
        ]
        for (nfc, nfd) in pairs {
            XCTAssertEqual(
                AgentHistorySearchText.normalize(nfc),
                AgentHistorySearchText.normalize(nfd),
                "\(nfc.unicodeScalars.map { String($0.value, radix: 16) })"
            )
            XCTAssertEqual(
                AgentHistorySearchText.normalizeWithMap(nfc).text,
                AgentHistorySearchText.normalizeWithMap(nfd).text
            )
        }
        XCTAssertEqual(AgentHistorySearchText.normalize("\u{304B}\u{3099}"), "\u{304C}")
    }

    func test_width_folding_fullwidth_ascii() {
        XCTAssertEqual(AgentHistorySearchText.normalize("ＨＥＬＬＯ\u{3000}ｗｏｒｌｄ１２３"), "hello world123")
        XCTAssertEqual(AgentHistorySearchText.normalize("＂ｑ＂"), "\"q\"")
        XCTAssertEqual(AgentHistorySearchText.normalize("ｶﾞｲﾄﾞ"), AgentHistorySearchText.normalize("ガイド"))
        XCTAssertEqual(AgentHistorySearchText.normalize("ＣａｆÉ"), "cafe")
    }

    func test_map_handles_length_changing_characters() {
        // `İ` lowercases to two scalars and folds to one byte.
        let dotted = "İstanbul"
        let dottedMap = AgentHistorySearchText.normalizeWithMap(dotted)
        XCTAssertEqual(dottedMap.text, "istanbul")
        assertMapInvariants(dottedMap, source: dotted)
        XCTAssertEqual(dottedMap.sourceRange(forBytes: 0..<1), NSRange(location: 0, length: 1))
        XCTAssertEqual(substring(dotted, dottedMap, bytesOf: "stanbul"), "stanbul")

        // A ligature stays one UTF-16 unit but is three UTF-8 bytes.
        let ligature = "ﬁle ﬁnder"
        let ligatureMap = AgentHistorySearchText.normalizeWithMap(ligature)
        assertMapInvariants(ligatureMap, source: ligature)
        XCTAssertEqual(substring(ligature, ligatureMap, bytesOf: "nder"), "nder")
        let firstLigatureBytes = 0..<"ﬁ".utf8.count
        XCTAssertEqual(ligatureMap.sourceRange(forBytes: firstLigatureBytes), NSRange(location: 0, length: 1))

        // A ZWJ emoji sequence is one Character over many UTF-16 units.
        let emoji = "👨‍👩‍👧 Family Trip"
        let emojiMap = AgentHistorySearchText.normalizeWithMap(emoji)
        XCTAssertEqual(emojiMap.text, "👨‍👩‍👧 family trip")
        assertMapInvariants(emojiMap, source: emoji)
        XCTAssertEqual(substring(emoji, emojiMap, bytesOf: "family"), "Family")
        XCTAssertEqual(substring(emoji, emojiMap, bytesOf: "trip"), "Trip")
        XCTAssertEqual(
            emojiMap.sourceRange(forBytes: 0..<"👨‍👩‍👧".utf8.count),
            NSRange(location: 0, length: ("👨‍👩‍👧" as NSString).length)
        )

        // Decomposed input maps folded bytes back to the whole grapheme.
        let decomposed = "Cafe\u{0301} au lait"
        let decomposedMap = AgentHistorySearchText.normalizeWithMap(decomposed)
        XCTAssertEqual(decomposedMap.text, "cafe au lait")
        XCTAssertEqual(substring(decomposed, decomposedMap, bytesOf: "cafe"), "Cafe\u{0301}")
        XCTAssertEqual(substring(decomposed, decomposedMap, bytesOf: "lait"), "lait")

        // A collapsed whitespace run maps back to the whole run.
        let spaced = "a \t\n b"
        let spacedMap = AgentHistorySearchText.normalizeWithMap(spaced)
        XCTAssertEqual(spacedMap.text, "a b")
        XCTAssertEqual(spacedMap.sourceRange(forBytes: 1..<2), NSRange(location: 1, length: 4))
        XCTAssertEqual(spacedMap.sourceRange(forBytes: 2..<2), NSRange(location: 5, length: 0))
        XCTAssertEqual(spacedMap.sourceRange(forBytes: 3..<3), NSRange(location: 6, length: 0))
    }

    func test_with_map_text_equals_normalize_for_fuzz_corpus() {
        var generator = SeededGenerator(seed: 0x5EA2C4)
        let pieces: [String] = [
            "a", "Z", "q", "0", "9", " ", "  ", "\t", "\n", "\r\n", "\u{0B}", "\u{0C}", "_", "-", "/", "'", "\"",
            "é", "e\u{0301}", "Ñ", "n\u{0303}", "ü", "Å", "ß", "ẞ", "ø", "İ", "ı", "ﬁ", "ﬀ", "Ǆ", "Σ", "ς",
            "Ά", "ω", "Ё", "й", "Ж", "Ứ", "U\u{031B}\u{0301}",
            "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}", "\u{201C}", "\u{201D}", "\u{201E}",
            "\u{201F}", "\u{2033}", "«", "»",
            "が", "か\u{3099}", "パ", "ﾊﾟ", "ｶﾞ", "ア", "ー", "中", "文", "搜", "한", "\u{1112}\u{1161}\u{11AB}",
            "Ａ", "ｚ", "１", "＂", "\u{3000}", "\u{00A0}", "\u{2028}", "\u{200B}", "\u{0301}", "\u{20DD}",
            "👍", "👍🏽", "👨‍👩‍👧", "🇧🇪", "❤️", "ä̈", "ل", "ש", "ก", "ำ", "हि", "\u{FEFF}",
        ]
        for index in 0..<300 {
            let length = Int(generator.next() % 24)
            var source = ""
            for _ in 0..<length {
                source += pieces[Int(generator.next() % UInt64(pieces.count))]
            }
            let plain = AgentHistorySearchText.normalize(source)
            let mapped = AgentHistorySearchText.normalizeWithMap(source)
            XCTAssertEqual(plain, mapped.text, "corpus #\(index)")
            assertMapInvariants(mapped, source: source)
        }
    }

    func test_is_cjk_and_contains_word_character() {
        for scalar in ["中", "文", "が", "カ", "ｶ", "한", "\u{1100}", "々", "\u{20000}", "ㄅ"].map({ $0.unicodeScalars.first! }) {
            XCTAssertTrue(AgentHistorySearchText.isCJK(scalar), "U+\(String(scalar.value, radix: 16))")
        }
        for scalar in ["a", "é", "Ж", "1", " ", "。", "「", "👍", "ل"].map({ $0.unicodeScalars.first! }) {
            XCTAssertFalse(AgentHistorySearchText.isCJK(scalar), "U+\(String(scalar.value, radix: 16))")
        }

        XCTAssertTrue(AgentHistorySearchText.containsWordCharacter("abc"))
        XCTAssertTrue(AgentHistorySearchText.containsWordCharacter("--x--"))
        XCTAssertTrue(AgentHistorySearchText.containsWordCharacter("42"))
        XCTAssertTrue(AgentHistorySearchText.containsWordCharacter("中文"))
        XCTAssertTrue(AgentHistorySearchText.containsWordCharacter("がか"))
        XCTAssertTrue(AgentHistorySearchText.containsWordCharacter("ελ"))
        XCTAssertFalse(AgentHistorySearchText.containsWordCharacter(""))
        XCTAssertFalse(AgentHistorySearchText.containsWordCharacter("   "))
        XCTAssertFalse(AgentHistorySearchText.containsWordCharacter("--->"))
        XCTAssertFalse(AgentHistorySearchText.containsWordCharacter("\"'()[]{}"))
        XCTAssertFalse(AgentHistorySearchText.containsWordCharacter("。、「」"))
        XCTAssertFalse(AgentHistorySearchText.containsWordCharacter("👍🎉"))
    }

    // MARK: - Helpers

    private func substring(_ source: String, _ map: AgentHistoryNormalizedText, bytesOf needle: String) -> String? {
        guard let range = map.text.range(of: needle) else {
            return nil
        }
        let lower = map.text.utf8.distance(from: map.text.utf8.startIndex, to: range.lowerBound)
        let upper = map.text.utf8.distance(from: map.text.utf8.startIndex, to: range.upperBound)
        return (source as NSString).substring(with: map.sourceRange(forBytes: lower..<upper))
    }

    private func assertMapInvariants(
        _ map: AgentHistoryNormalizedText,
        source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let utf16Count = Int32((source as NSString).length)
        XCTAssertEqual(map.utf8, Array(map.text.utf8), file: file, line: line)
        XCTAssertEqual(map.sourceStart.count, map.utf8.count, file: file, line: line)
        XCTAssertEqual(map.sourceEnd.count, map.utf8.count, file: file, line: line)
        var previousStart: Int32 = 0
        for index in map.utf8.indices {
            let start = map.sourceStart[index]
            let end = map.sourceEnd[index]
            XCTAssertLessThanOrEqual(0, start, file: file, line: line)
            XCTAssertLessThan(start, end, file: file, line: line)
            XCTAssertLessThanOrEqual(end, utf16Count, file: file, line: line)
            XCTAssertLessThanOrEqual(previousStart, start, file: file, line: line)
            previousStart = start
        }
        let whole = map.sourceRange(forBytes: 0..<map.utf8.count)
        XCTAssertLessThanOrEqual(whole.location + whole.length, Int(utf16Count), file: file, line: line)
    }
}

/// SplitMix64, so the fuzz corpus is identical on every run.
private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
