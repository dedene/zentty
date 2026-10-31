import XCTest
@testable import Zentty

/// Commands pulled out of code-mode `exec` inputs.
final class CodexExecInputTests: XCTestCase {
    func test_reads_every_literal_cmd_in_order() {
        let input = #"""
            text(await tools.exec_command({cmd:"cat README.md","max_output_tokens":10000}));
            text(await tools.exec_command({"cmd":"git diff --stat 0a2c..HEAD", max_output_tokens: 6000}));
            text(await tools.exec_command({ yield_time_ms: 1000, cmd: 'ls -la' }));
            """#
        XCTAssertEqual(CodexExecInput.commands(in: input), ["cat README.md", "git diff --stat 0a2c..HEAD", "ls -la"])
    }

    func test_decodes_escapes_and_keeps_template_placeholders() {
        let input = #"""
            text(await tools.exec_command({cmd:"rg -n 'describe \"#tw' spec\nprintf \"é😀\"","max_output_tokens":6000}));
            const r = await tools.exec_command({cmd:`gh api 'repos/zenjoy/${repo}/contents/${p}?ref=${sha}' | nl -ba`,yield_time_ms:1000});
            """#
        XCTAssertEqual(CodexExecInput.commands(in: input), [
            "rg -n 'describe \"#tw' spec\nprintf \"é😀\"",
            "gh api 'repos/zenjoy/${repo}/contents/${p}?ref=${sha}' | nl -ba",
        ])
    }

    func test_skips_values_before_cmd_and_non_literal_cmds() {
        let input = #"""
            await tools.exec_command({workdir:"/a,b}", env:{A:"1", B:[1,2,{c:3}]}, cmd:"make test"});
            await tools.exec_command({cmd: commands[i], max_output_tokens: 100});
            await tools.exec_command(options);
            await tools.write_stdin({session_id: 3, chars: "y\n"});
            """#
        XCTAssertEqual(CodexExecInput.commands(in: input), ["make test"])
    }

    func test_tolerates_truncated_input() {
        XCTAssertEqual(CodexExecInput.commands(in: #"tools.exec_command({cmd:"git sta"#), [])
        XCTAssertEqual(CodexExecInput.commands(in: #"tools.exec_command({env:"unterminated, cmd:"x"})"#), [])
        XCTAssertEqual(CodexExecInput.commands(in: "tools.exec_command("), [])
        XCTAssertEqual(CodexExecInput.commands(in: ""), [])
    }
}
