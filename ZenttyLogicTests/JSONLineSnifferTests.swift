import Foundation
import XCTest
@testable import Zentty

final class JSONLineSnifferTests: XCTestCase {
    private func topLevel(
        _ line: String,
        strings: [String] = ["type"],
        flags: [String] = [],
        presence: [String] = []
    ) -> JSONLineSniffer.TopLevel? {
        Array(line.utf8).withUnsafeBytes {
            JSONLineSniffer.topLevel(in: $0, stringKeys: strings, flagKeys: flags, presenceKeys: presence)
        }
    }

    private func value(_ path: [JSONLineSniffer.PathComponent], _ line: String) -> JSONLineSniffer.Value? {
        Array(line.utf8).withUnsafeBytes { JSONLineSniffer.value(at: path, in: $0) }
    }

    private func contains(_ needle: String, _ line: String) -> Bool {
        Array(line.utf8).withUnsafeBytes { JSONLineSniffer.contains(needle, in: $0) }
    }

    func test_type_first_key_fast_path() {
        let result = topLevel(#"{"type":"user","message":{"role":"user","content":"hi"}}"#)
        XCTAssertEqual(result?.strings, ["type": "user"])
        XCTAssertEqual(result?.trueFlags, [])
        XCTAssertEqual(result?.presentKeys, [])

        // The fast path stops before the rest of the line, so trailing damage does not matter.
        XCTAssertEqual(topLevel(#"{"type":"ai-title","aiTitle":"x" GARBAGE"#)?.strings["type"], "ai-title")
    }

    func test_type_after_large_nested_message() {
        let bigText = String(repeating: "lorem {\\\"type\\\":\\\"fake\\\"} [ipsum] ", count: 4_000)
        let line = #"{"parentUuid":null,"message":{"role":"assistant","content":[{"type":"text","text":""#
            + bigText
            + #""},{"type":"tool_use","input":{"type":"nested","list":[1,2,{"type":"x"}]}}]},"isSidechain":false,"type":"assistant","uuid":"u1"}"#
        XCTAssertGreaterThan(line.utf8.count, 100_000)

        let result = topLevel(line, strings: ["type", "uuid"], flags: ["isSidechain"], presence: ["parentUuid"])
        XCTAssertEqual(result?.strings, ["type": "assistant", "uuid": "u1"])
        XCTAssertEqual(result?.trueFlags, [], "isSidechain is false")
        XCTAssertEqual(result?.presentKeys, [], "null does not count as present")
    }

    func test_nested_type_ignored() {
        let line = #"{"message":{"type":"inner","content":[{"type":"deep"}]},"other":{"type":"x"}}"#
        let result = topLevel(line)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.strings["type"])
    }

    func test_escaped_quotes_and_backslashes() {
        let line = #"{"message":"say \"type\":\"no\" \\","path":"C:\\dir\\\"q\"","type":"tab\there \u00e9 \ud83d\ude00 \/"}"#
        let result = topLevel(line, strings: ["type", "path"])
        XCTAssertEqual(result?.strings["type"], "tab\there é 😀 /")
        XCTAssertEqual(result?.strings["path"], #"C:\dir\"q""#)

        let escapedKey = #"{"ty\u0070e":"escaped-key"}"#
        XCTAssertEqual(topLevel(escapedKey)?.strings["type"], "escaped-key")

        XCTAssertEqual(topLevel(#"{"type":"\ud800 lone"}"#)?.strings["type"], "\u{FFFD} lone")
    }

    func test_true_flags_and_present_keys() {
        let line = """
        {"isMeta":true,"isSidechain":false,"isCompactSummary":"true","toolUseResult":{"x":1},\
        "forkedFrom":null,"origin":[],"empty":"","type":"user"}
        """
        let result = topLevel(
            line,
            strings: ["type", "missing"],
            flags: ["isMeta", "isSidechain", "isCompactSummary", "absent"],
            presence: ["toolUseResult", "forkedFrom", "origin", "empty", "nope"]
        )
        XCTAssertEqual(result?.strings, ["type": "user"])
        XCTAssertEqual(result?.trueFlags, ["isMeta"])
        XCTAssertEqual(result?.presentKeys, ["toolUseResult", "origin", "empty"])
    }

    func test_string_key_with_non_string_value_is_absent() {
        XCTAssertEqual(topLevel(#"{"type":42}"#)?.strings, [:])
        XCTAssertEqual(topLevel(#"{"type":{"a":"b"}}"#)?.strings, [:])
    }

    func test_whitespace_between_tokens() {
        let result = topLevel(" { \"a\" : [ 1 , 2 ] ,\n\t\"type\" :  \"spaced\" } ", strings: ["type"])
        XCTAssertEqual(result?.strings["type"], "spaced")
        XCTAssertEqual(topLevel("{ }")?.strings, [:])
    }

    func test_path_first_content_part_type() {
        let toolResult = #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t","type":"tool_result","content":"ok"},{"type":"text"}]}}"#
        XCTAssertEqual(
            value([.key("message"), .key("content"), .index(0), .key("type")], toolResult),
            .string("tool_result")
        )
        XCTAssertEqual(
            value([.key("message"), .key("content"), .index(1), .key("type")], toolResult),
            .string("text")
        )
        XCTAssertNil(value([.key("message"), .key("content"), .index(2), .key("type")], toolResult))

        let stringContent = #"{"type":"user","message":{"role":"user","content":"plain"}}"#
        XCTAssertNil(value([.key("message"), .key("content"), .index(0), .key("type")], stringContent))
        XCTAssertEqual(value([.key("message"), .key("content")], stringContent), .string("plain"))
    }

    func test_value_kinds() {
        let line = #"{"s":"x","t":true,"f":false,"n":-1.5e3,"z":null,"o":{"k":1},"a":[1,[2]],"type":"y"}"#
        XCTAssertEqual(value([.key("s")], line), .string("x"))
        XCTAssertEqual(value([.key("t")], line), .bool(true))
        XCTAssertEqual(value([.key("f")], line), .bool(false))
        XCTAssertEqual(value([.key("n")], line), .number)
        XCTAssertEqual(value([.key("z")], line), .null)
        XCTAssertEqual(value([.key("o")], line), .object)
        XCTAssertEqual(value([.key("a")], line), .array)
        XCTAssertEqual(value([.key("a"), .index(1), .index(0)], line), .number)
        XCTAssertEqual(value([], line), .object)
        XCTAssertNil(value([.key("missing")], line))
        XCTAssertNil(value([.key("s"), .key("deeper")], line))
        XCTAssertNil(value([.index(0)], line))
    }

    func test_contains_memmem() {
        let line = #"{"type":"user","toolUseResult":{"gitOperation":{"commit":{"sha":"abc"}}}}"#
        XCTAssertTrue(contains("\"gitOperation\"", line))
        XCTAssertFalse(contains("\"turn_started\"", line))
        XCTAssertTrue(contains("", line))
        XCTAssertFalse(contains("x", ""))
        XCTAssertTrue(contains(line, line))
        XCTAssertFalse(contains(line + "!", line))
    }

    func test_malformed_returns_nil() {
        let malformed = [
            "",
            "not json",
            "[1,2,3]",
            "\"type\"",
            #"{"type":"#,
            #"{"type":"unterminated"#,
            #"{"message":{"a":1},"type""#,
            #"{"message":{"a":1}"#,
            #"{"a":1 "type":"x"}"#,
            #"{type:"x"}"#,
            #"{"a":tru,"type":"x"}"#,
            #"{"a":"\x","type":"x"}"#,
            #"{"a":"\u12G4","type":"x"}"#,
            #"{"a":[1,2},"type":"x"}"#,
        ]
        for line in malformed {
            XCTAssertNil(topLevel(line), "expected nil for \(line)")
        }
        XCTAssertNil(value([.key("type")], #"{"a":[1,2},"type":"x"}"#))
        XCTAssertNil(value([.key("type")], "garbage"))
    }
}
