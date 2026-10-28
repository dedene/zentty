import GhosttyKit
import XCTest
@testable import Zentty

/// Terminal output controls `link` matches (kind unknown) and OSC 8 targets, so a Cmd-click on
/// them must never launch an app or executable straight through Launch Services.
final class TerminalOpenURLPolicyTests: XCTestCase {
    // MARK: - Payload

    func test_copy_action_payload_carries_open_url_kind() {
        let cases: [(ghostty_action_open_url_kind_e, TerminalOpenURLKind)] = [
            (GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, .unknown),
            (GHOSTTY_ACTION_OPEN_URL_KIND_TEXT, .text),
            (GHOSTTY_ACTION_OPEN_URL_KIND_HTML, .html),
            (GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, .osc8),
        ]
        for (cKind, kind) in cases {
            let url = "file:///tmp/payload.command"
            let payload = url.withCString { pointer in
                copyLibghosttySurfaceActionPayload(from: ghostty_action_s(
                    tag: GHOSTTY_ACTION_OPEN_URL,
                    action: ghostty_action_u(open_url: ghostty_action_open_url_s(
                        kind: cKind,
                        url: pointer,
                        len: UInt(url.utf8.count)
                    ))
                ))
            }
            XCTAssertEqual(payload, .openURL(url, kind: kind))
        }
    }

    // MARK: - Untrusted kinds

    func test_link_match_to_app_bundle_is_blocked() throws {
        let directory = try makeTemporaryDirectory()
        let app = directory.appending(path: "Calculator.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)

        let decision = TerminalOpenURLPolicy.decision(for: app.absoluteString, kind: .unknown, workingDirectory: nil)

        XCTAssertEqual(decision, .block(.unsafeFile, displayString: canonical(app).path))
    }

    func test_link_match_to_system_application_is_blocked() throws {
        let calculator = "/System/Applications/Calculator.app"
        guard FileManager.default.fileExists(atPath: calculator) else {
            throw XCTSkip("Calculator.app is not installed")
        }

        let decision = TerminalOpenURLPolicy.decision(
            for: "file://\(calculator)",
            kind: .unknown,
            workingDirectory: nil
        )

        guard case .block(.unsafeFile, _) = decision else {
            return XCTFail("expected a blocked app, got \(decision)")
        }
    }

    func test_link_match_relative_path_resolves_against_working_directory_and_opens() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "notes.txt")
        try "safe".write(to: file, atomically: true, encoding: .utf8)

        let decision = TerminalOpenURLPolicy.decision(
            for: "notes.txt.",
            kind: .unknown,
            workingDirectory: directory.path
        )

        XCTAssertEqual(decision, .open(canonical(file)))
    }

    func test_link_match_relative_script_is_blocked() throws {
        let directory = try makeTemporaryDirectory()
        let script = directory.appending(path: "build.sh")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)

        let decision = TerminalOpenURLPolicy.decision(
            for: "./build.sh",
            kind: .unknown,
            workingDirectory: directory.path
        )

        XCTAssertEqual(decision, .block(.unsafeFile, displayString: canonical(script).path))
    }

    func test_link_match_missing_path_is_blocked() throws {
        let directory = try makeTemporaryDirectory()

        let decision = TerminalOpenURLPolicy.decision(
            for: "docs/missing.md",
            kind: .unknown,
            workingDirectory: directory.path
        )

        guard case .block(.inaccessibleFile, _) = decision else {
            return XCTFail("expected a blocked missing file, got \(decision)")
        }
    }

    func test_link_match_path_with_control_characters_is_blocked_before_encoding() {
        let decision = TerminalOpenURLPolicy.decision(
            for: "notes\u{1B}]52;c;SGVsbG8=\u{07}.txt",
            kind: .unknown,
            workingDirectory: "/tmp"
        )

        guard case .block(.unsafeCharacters, let displayString) = decision else {
            return XCTFail("expected unsafe characters to be blocked, got \(decision)")
        }
        XCTAssertFalse(displayString.contains("\u{1B}"))
        XCTAssertFalse(displayString.contains("\u{07}"))
    }

    func test_link_match_web_url_opens_directly() {
        XCTAssertEqual(
            TerminalOpenURLPolicy.decision(for: "https://example.com/a", kind: .unknown, workingDirectory: "/repo"),
            .open(URL(string: "https://example.com/a")!)
        )
    }

    func test_osc8_custom_scheme_asks_for_confirmation() {
        XCTAssertEqual(
            TerminalOpenURLPolicy.decision(for: "vscode://file/tmp/a.swift", kind: .osc8, workingDirectory: nil),
            .confirm(URL(string: "vscode://file/tmp/a.swift")!, displayString: "vscode://file/tmp/a.swift")
        )
    }

    func test_osc8_scheme_less_target_is_blocked() throws {
        let directory = try makeTemporaryDirectory()
        try "safe".write(to: directory.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

        let decision = TerminalOpenURLPolicy.decision(for: "notes.txt", kind: .osc8, workingDirectory: directory.path)

        guard case .block(.malformedURL, _) = decision else {
            return XCTFail("expected a scheme-less OSC 8 target to be blocked, got \(decision)")
        }
    }

    func test_empty_link_match_is_blocked_instead_of_opening_working_directory() {
        guard case .block(.malformedURL, _) = TerminalOpenURLPolicy.decision(
            for: "",
            kind: .unknown,
            workingDirectory: "/tmp"
        ) else {
            return XCTFail("expected an empty target to be blocked")
        }
    }

    // MARK: - Trusted kinds

    func test_trusted_kinds_keep_resolver_behavior() {
        for kind in [TerminalOpenURLKind.text, .html] {
            let decision = TerminalOpenURLPolicy.decision(
                for: "docs/design.md.",
                kind: kind,
                workingDirectory: "/repo",
                fileExists: { $0 == "/repo/docs/design.md" }
            )
            XCTAssertEqual(decision, .open(URL(filePath: "/repo/docs/design.md")), "kind \(kind)")
        }
    }

    // MARK: - TerminalUntrustedURL

    func test_untrusted_url_allows_web_and_mail_schemes() {
        for value in ["http://example.com", "https://example.com/path", "mailto:user@example.com"] {
            XCTAssertEqual(TerminalUntrustedURL(value).decision, .allow(URL(string: value)!), value)
        }
    }

    func test_untrusted_url_rejects_web_urls_without_hosts() {
        for value in ["https:relative", "http:///missing-host"] {
            XCTAssertEqual(TerminalUntrustedURL(value).decision, .deny(.invalidWebURL), value)
        }
    }

    func test_untrusted_url_rejects_bare_mailto_and_scheme_less_targets() {
        for value in ["mailto:", "/tmp/file.txt", "../file.txt", "payload.command"] {
            XCTAssertEqual(TerminalUntrustedURL(value).decision, .deny(.malformedURL), value)
        }
    }

    func test_untrusted_url_rejects_remote_file_hosts_queries_and_fragments() {
        for value in ["file://evil.example/tmp/a.txt", "file:///tmp/a.txt?x=1", "file:///tmp/a.txt#frag"] {
            XCTAssertEqual(TerminalUntrustedURL(value).decision, .deny(.malformedURL), value)
        }
    }

    func test_untrusted_url_confirms_custom_schemes() {
        for value in ["vscode://file/tmp/example.swift", "ssh://example.com", "x-apple.systempreferences:"] {
            XCTAssertEqual(TerminalUntrustedURL(value).decision, .confirm(URL(string: value)!), value)
        }
    }

    func test_untrusted_url_rejects_invisible_and_line_breaking_characters() {
        for scalar in ["\u{1B}", "\u{07}", "\u{0085}", "\u{2028}", "\u{2029}", "\u{202E}", "\u{2066}", "\u{FEFF}"] {
            let value = "https://example.com/before\(scalar)after"
            XCTAssertEqual(TerminalUntrustedURL(value).decision, .deny(.unsafeCharacters), value.debugDescription)
        }
    }

    func test_untrusted_url_allows_non_executable_files_and_directories() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "document.txt")
        try "safe".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(TerminalUntrustedURL(file.absoluteString).decision, .allow(canonical(file)))
        XCTAssertEqual(TerminalUntrustedURL(directory.absoluteString).decision, .allow(canonical(directory)))
    }

    func test_untrusted_url_rejects_dangerous_extensions_even_without_execute_bit() throws {
        let directory = try makeTemporaryDirectory()
        for filename in ["payload.command", "payload.tool", "payload.workflow", "payload.terminal", "payload.webloc"] {
            let file = directory.appending(path: filename)
            try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
            XCTAssertEqual(TerminalUntrustedURL(file.absoluteString).decision, .deny(.unsafeFile), filename)
        }
    }

    func test_untrusted_url_rejects_script_content_types() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "payload.sh")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(TerminalUntrustedURL(file.absoluteString).decision, .deny(.unsafeFile))
    }

    func test_untrusted_url_rejects_executable_files_regardless_of_extension() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "payload.txt")
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

        XCTAssertEqual(TerminalUntrustedURL(file.absoluteString).decision, .deny(.unsafeFile))
    }

    func test_untrusted_url_resolves_symlinks_before_classifying() throws {
        let directory = try makeTemporaryDirectory()
        let payload = directory.appending(path: "payload.command")
        let link = directory.appending(path: "document.txt")
        try "#!/bin/sh\n".write(to: payload, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: payload)

        XCTAssertEqual(TerminalUntrustedURL(link.absoluteString).decision, .deny(.unsafeFile))
    }

    func test_untrusted_url_rejects_missing_files_and_special_files() {
        XCTAssertEqual(
            TerminalUntrustedURL("file:///nonexistent/zentty-\(UUID().uuidString)").decision,
            .deny(.inaccessibleFile)
        )
        XCTAssertEqual(TerminalUntrustedURL("file:///dev/null").decision, .deny(.inaccessibleFile))
    }

    func test_display_string_shows_the_effective_standardized_path() {
        for separator in ["\u{0085}", "\u{2028}", "\u{2029}"] {
            let value = "/tmp/preview\(separator)////../payload.command////"
            XCTAssertEqual(TerminalUntrustedURL(value).displayString, "/tmp/payload.command")
        }
    }

    func test_display_string_escapes_bidirectional_controls() {
        XCTAssertEqual(
            TerminalUntrustedURL("https://example.com/a\u{202E}b").displayString,
            "https://example.com/a\\u{202E}b"
        )
    }

    // MARK: - Helpers

    private func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TerminalOpenURLPolicyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
