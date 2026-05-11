import Foundation
import XCTest
@testable import Zentty

final class CodexTranscriptQuestionExtractorTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func test_extracts_latest_request_user_input_question_from_transcript_tail() throws {
        let transcript = """
        {"type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\\"questions\\":[{\\"header\\":\\"Random\\",\\"id\\":\\"weekend_breakfast\\",\\"question\\":\\"What is your ideal weekend breakfast?\\",\\"options\\":[{\\"label\\":\\"Coffee + pastry\\",\\"description\\":\\"Simple and low-effort.\\"},{\\"label\\":\\"Eggs + toast\\",\\"description\\":\\"Classic and filling.\\"},{\\"label\\":\\"Pancakes\\",\\"description\\":\\"A slower, sweeter start.\\"}]}]}","call_id":"call_1"}}
        """

        let question = try XCTUnwrap(CodexTranscriptQuestionExtractor.question(fromTranscriptText: transcript))

        XCTAssertEqual(
            question.text,
            "What is your ideal weekend breakfast?\n[Coffee + pastry] [Eggs + toast] [Pancakes]"
        )
        XCTAssertEqual(question.interactionKind, .decision)
    }

    func test_extracts_newest_matching_request_user_input_question() throws {
        let transcript = """
        {"type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\\"questions\\":[{\\"question\\":\\"Old question?\\",\\"options\\":[{\\"label\\":\\"Old\\"}]}]}"}}
        {"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\\"command\\":\\"echo ok\\"}"}}
        {"type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\\"questions\\":[{\\"question\\":\\"New question?\\",\\"options\\":[{\\"label\\":\\"Yes\\"},{\\"label\\":\\"No\\"}]}]}"}}
        """

        let question = try XCTUnwrap(CodexTranscriptQuestionExtractor.question(fromTranscriptText: transcript))

        XCTAssertEqual(question.text, "New question?\n[Yes] [No]")
    }

    func test_extracts_ask_user_question_alias_from_transcript() throws {
        let transcript = """
        {"type":"response_item","payload":{"type":"function_call","name":"AskUserQuestion","arguments":"{\\"question\\":\\"Which file should I update?\\",\\"options\\":[{\\"label\\":\\"README\\"},{\\"label\\":\\"Tests\\"}]}"}}
        """

        let question = try XCTUnwrap(CodexTranscriptQuestionExtractor.question(fromTranscriptText: transcript))

        XCTAssertEqual(question.text, "Which file should I update?\n[README] [Tests]")
    }

    func test_extracts_top_level_question_tool_input() throws {
        let question = try XCTUnwrap(
            CodexTranscriptQuestionExtractor.question(fromToolInput: [
                "question": "Which season do you like most?",
                "options": [
                    ["label": "Spring"],
                    ["label": "Autumn"],
                ],
            ])
        )

        XCTAssertEqual(question.text, "Which season do you like most?\n[Spring] [Autumn]")
        XCTAssertEqual(question.interactionKind, .decision)
    }

    func test_returns_nil_for_malformed_or_unrelated_transcript_lines() {
        let transcript = """
        not json
        {"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\\"command\\":\\"echo ok\\"}"}}
        {"type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"not json"}}
        """

        XCTAssertNil(CodexTranscriptQuestionExtractor.question(fromTranscriptText: transcript))
    }

    func test_locates_recent_codex_transcript_for_matching_working_directory() throws {
        let home = try makeTemporaryDirectory()
        let sessions = home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("05", isDirectory: true)
            .appendingPathComponent("11", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let unrelated = sessions.appendingPathComponent("rollout-unrelated.jsonl")
        try writeTranscript(
            at: unrelated,
            cwd: "/tmp/other",
            question: "Wrong question?"
        )

        let matching = sessions.appendingPathComponent("rollout-matching.jsonl")
        try writeTranscript(
            at: matching,
            cwd: "/tmp/project",
            question: "Which small upgrade would you pick today?"
        )

        let located = try XCTUnwrap(CodexTranscriptQuestionExtractor.locateRecentTranscriptPath(
            workingDirectory: "/tmp/project",
            environment: ["CODEX_HOME": home.path],
            now: Date(timeIntervalSince1970: 1_778_499_600)
        ))

        XCTAssertEqual(located, matching.path)
        let question = try XCTUnwrap(CodexTranscriptQuestionExtractor.question(fromTranscriptPath: located))
        XCTAssertEqual(question.text, "Which small upgrade would you pick today?\n[Better coffee]")
    }

    func test_does_not_locate_unrelated_question_when_working_directory_is_known() throws {
        let home = try makeTemporaryDirectory()
        let sessions = home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("05", isDirectory: true)
            .appendingPathComponent("11", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        try writeTranscript(
            at: sessions.appendingPathComponent("rollout-unrelated.jsonl"),
            cwd: "/tmp/other",
            question: "Wrong question?"
        )

        XCTAssertNil(CodexTranscriptQuestionExtractor.locateRecentTranscriptPath(
            workingDirectory: "/tmp/project",
            environment: ["CODEX_HOME": home.path],
            now: Date(timeIntervalSince1970: 1_778_499_600)
        ))
    }

    func test_does_not_guess_transcript_when_working_directory_is_missing() throws {
        let home = try makeTemporaryDirectory()
        let sessions = home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("05", isDirectory: true)
            .appendingPathComponent("11", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        try writeTranscript(
            at: sessions.appendingPathComponent("rollout-question.jsonl"),
            cwd: "/tmp/project",
            question: "Which small upgrade would you pick today?"
        )

        XCTAssertNil(CodexTranscriptQuestionExtractor.locateRecentTranscriptPath(
            workingDirectory: nil,
            environment: ["CODEX_HOME": home.path],
            now: Date(timeIntervalSince1970: 1_778_499_600)
        ))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CodexTranscriptQuestionExtractorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func writeTranscript(at url: URL, cwd: String, question: String) throws {
        let transcript = """
        {"type":"turn_context","payload":{"cwd":"\(cwd)"}}
        {"type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\\"questions\\":[{\\"header\\":\\"Random\\",\\"id\\":\\"upgrade\\",\\"question\\":\\"\(question)\\",\\"options\\":[{\\"label\\":\\"Better coffee\\",\\"description\\":\\"A small comfort boost.\\"}]}]}","call_id":"call_1"}}
        """
        try transcript.write(to: url, atomically: true, encoding: .utf8)
    }
}
