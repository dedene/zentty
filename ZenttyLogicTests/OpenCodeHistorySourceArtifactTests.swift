import Foundation
import XCTest
@testable import Zentty

/// Commands, commit hashes and file paths from both generations' tool calls.
final class OpenCodeHistorySourceArtifactTests: OpenCodeHistorySourceTestCase {
    func test_artifacts_bash_edit_write_patch() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self, v2: false)
        let t = Self.t0
        try fixture.addSession("ses_art", directory: "/work/repo", createdMs: t, updatedMs: t)
        try fixture.addMessage("msg_1", session: "ses_art", role: "assistant", createdMs: t + 1)
        try fixture.addTextPart("prt_0", message: "msg_1", session: "ses_art", text: "Making the change", createdMs: t + 1)
        try fixture.addToolPart("prt_1", message: "msg_1", session: "ses_art", tool: "bash",
                                input: ["command": "git commit -m 'Fix login'"],
                                output: "[main 1a2b3c4] Fix login\n 1 file changed", createdMs: t + 2)
        try fixture.addToolPart("prt_2", message: "msg_1", session: "ses_art", tool: "bash",
                                input: ["command": "echo [main deadbeef1] nope"], output: "[main deadbeef1] nope", createdMs: t + 3)
        try fixture.addToolPart("prt_3", message: "msg_1", session: "ses_art", tool: "edit",
                                input: ["filePath": "/work/repo/Sources/A.swift", "oldString": "a", "newString": "b"], createdMs: t + 4)
        try fixture.addToolPart("prt_4", message: "msg_1", session: "ses_art", tool: "write",
                                input: ["filePath": "/elsewhere/notes.md", "content": "x"], createdMs: t + 5)
        try fixture.addToolPart("prt_5", message: "msg_1", session: "ses_art", tool: "apply_patch", input: [
            "patchText": "*** Begin Patch\n*** Update File: Sources/B.swift\n@@\n*** Add File: Sources/C.swift\n+x\n*** End Patch",
        ], createdMs: t + 6)
        try fixture.addToolPart("prt_6", message: "msg_1", session: "ses_art", tool: "read",
                                input: ["filePath": "/work/repo/README.md"], createdMs: t + 7)

        let (batches, _) = try drain(makeSource(fixture))
        let artifacts = batches.flatMap(\.artifacts)
        XCTAssertEqual(artifacts.filter { $0.kind == .command }.map(\.value),
                       ["git commit -m 'Fix login'", "echo [main deadbeef1] nope"])
        XCTAssertEqual(artifacts.filter { $0.kind == .commit }.map(\.value), ["1a2b3c4"], "only git commit output")
        XCTAssertEqual(artifacts.filter { $0.kind == .path }.map(\.value),
                       ["Sources/A.swift", "/elsewhere/notes.md", "Sources/B.swift", "Sources/C.swift"])
    }

    func test_v2_commit_hash_from_metadata_output() throws {
        let fixture = try OpenCodeHistoryFixture(testCase: self)
        let t = Self.t0
        try fixture.addSession("ses_v2art", in: .v2, directory: "/work/repo", version: "2.0.0", createdMs: t, updatedMs: t)
        try fixture.addSessionMessage("msg_a", session: "ses_v2art", type: "assistant", seq: 1, data: [
            "content": [
                ["type": "tool", "id": "call_1", "name": "bash", "state": [
                    "status": "completed",
                    "input": ["command": "git commit -m 'Fix login'"],
                    "metadata": ["output": "[main 1a2b3c4] Fix login\n 1 file changed"],
                    "content": [["type": "text", "text": "Committed."]],
                ]],
                ["type": "tool", "id": "call_2", "name": "bash", "state": [
                    "status": "completed",
                    "input": ["command": "echo '[main deadbee] nope'"],
                    "metadata": ["output": "[main deadbee] nope"],
                ]],
            ],
        ], createdMs: t + 1)

        let (batches, _) = try drain(makeSource(fixture))
        let artifacts = batches.flatMap(\.artifacts)
        XCTAssertEqual(artifacts.filter { $0.kind == .command }.map(\.value),
                       ["git commit -m 'Fix login'", "echo '[main deadbee] nope'"])
        XCTAssertEqual(artifacts.filter { $0.kind == .commit }.map(\.value), ["1a2b3c4"],
                       "v2 reads state.metadata.output, and only for git commit")
    }
}
