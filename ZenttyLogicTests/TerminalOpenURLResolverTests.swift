import XCTest
@testable import Zentty

final class TerminalOpenURLResolverTests: XCTestCase {
    func test_scheme_url_passes_through_untouched() {
        let url = TerminalOpenURLResolver.resolve(
            "https://example.com/foo.",
            workingDirectory: "/repo",
            fileExists: { _ in false }
        )

        XCTAssertEqual(url.absoluteString, "https://example.com/foo.")
        XCTAssertEqual(url.scheme, "https")
    }

    func test_absolute_path_without_punctuation_resolves() {
        let url = TerminalOpenURLResolver.resolve(
            "/abs/dir/file.md",
            workingDirectory: nil,
            fileExists: { $0 == "/abs/dir/file.md" }
        )

        XCTAssertEqual(url.path, "/abs/dir/file.md")
    }

    func test_absolute_path_trailing_dot_stripped_when_literal_missing() {
        let url = TerminalOpenURLResolver.resolve(
            "/abs/dir/file.md.",
            workingDirectory: nil,
            fileExists: { $0 == "/abs/dir/file.md" }
        )

        XCTAssertEqual(url.path, "/abs/dir/file.md")
    }

    func test_relative_path_trailing_dot_resolves_against_working_directory() {
        let existing: Set<String> = ["/repo/docs/specs/design.md"]

        let url = TerminalOpenURLResolver.resolve(
            "docs/specs/design.md.",
            workingDirectory: "/repo",
            fileExists: existing.contains
        )

        XCTAssertEqual(url.path, "/repo/docs/specs/design.md")
    }

    func test_relative_path_trailing_sentence_punctuation_stripped() {
        let existing: Set<String> = ["/repo/docs/specs/design.md"]

        for suffix in [",", ";", ":"] {
            let url = TerminalOpenURLResolver.resolve(
                "docs/specs/design.md\(suffix)",
                workingDirectory: "/repo",
                fileExists: existing.contains
            )

            XCTAssertEqual(url.path, "/repo/docs/specs/design.md", "suffix \(suffix)")
        }
    }

    func test_multiple_trailing_punctuation_characters_stripped_one_at_a_time() {
        let existing: Set<String> = ["/repo/src/foo.md"]

        let url = TerminalOpenURLResolver.resolve(
            "src/foo.md.,",
            workingDirectory: "/repo",
            fileExists: existing.contains
        )

        XCTAssertEqual(url.path, "/repo/src/foo.md")
    }

    func test_dot_relative_path_resolves_against_working_directory() {
        let existing: Set<String> = ["/repo/notes.txt"]

        let url = TerminalOpenURLResolver.resolve(
            "./notes.txt.",
            workingDirectory: "/repo",
            fileExists: existing.contains
        )

        XCTAssertEqual(url.path, "/repo/notes.txt")
    }

    func test_tilde_path_expands_before_punctuation_stripping() {
        let homePath = NSString(string: "~/x.md").standardizingPath
        let existing: Set<String> = [homePath]

        let url = TerminalOpenURLResolver.resolve(
            "~/x.md.",
            workingDirectory: "/repo",
            fileExists: existing.contains
        )

        XCTAssertEqual(url.path, homePath)
    }

    func test_literal_path_ending_in_dot_wins_when_it_exists() {
        let existing: Set<String> = ["/abs/weird."]

        let url = TerminalOpenURLResolver.resolve(
            "/abs/weird.",
            workingDirectory: nil,
            fileExists: existing.contains
        )

        XCTAssertEqual(url.path, "/abs/weird.")
    }

    func test_missing_path_falls_back_to_first_candidate_resolved_against_working_directory() {
        let url = TerminalOpenURLResolver.resolve(
            "docs/missing.md.",
            workingDirectory: "/repo",
            fileExists: { _ in false }
        )

        XCTAssertEqual(url.path, "/repo/docs/missing.md.")
    }

    func test_missing_relative_path_without_working_directory_matches_previous_behaviour() {
        let expanded = NSString(string: "docs/missing.md.").standardizingPath

        let url = TerminalOpenURLResolver.resolve(
            "docs/missing.md.",
            workingDirectory: nil,
            fileExists: { _ in false }
        )

        XCTAssertEqual(url.path, URL(filePath: expanded).path)
    }

    // MARK: - Scheme-less web addresses

    /// Ghostty's link regex matches `example.com/path` as a relative path, so without this the
    /// click resolved to `<cwd>/example.com/path` and was blocked as a missing file.
    func test_bare_domain_with_path_and_query_opens_as_https() {
        let url = TerminalOpenURLResolver.resolve(
            "linkedin.com/ad-library/search?companyName=Dashdot",
            workingDirectory: "/repo",
            fileExists: { _ in false }
        )

        XCTAssertEqual(url.absoluteString, "https://linkedin.com/ad-library/search?companyName=Dashdot")
    }

    func test_bare_domain_variants_open_as_https() {
        let cases = [
            "www.example.com": "https://www.example.com",
            "docs.example.co.uk/guide#intro": "https://docs.example.co.uk/guide#intro",
            "my-site.dev?ref=terminal": "https://my-site.dev?ref=terminal",
        ]
        for (raw, expected) in cases {
            let url = TerminalOpenURLResolver.resolve(raw, workingDirectory: "/repo", fileExists: { _ in false })
            XCTAssertEqual(url.absoluteString, expected, raw)
        }
    }

    func test_existing_local_path_wins_over_bare_domain() {
        let existing: Set<String> = ["/repo/example.com/index.html"]

        let url = TerminalOpenURLResolver.resolve(
            "example.com/index.html",
            workingDirectory: "/repo",
            fileExists: existing.contains
        )

        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url.path, "/repo/example.com/index.html")
    }

    func test_path_like_targets_are_not_mistaken_for_domains() {
        for raw in [
            "README.md",
            "docs/missing.md",
            "./example.com/x",
            "../example.com/x",
            "~/example.com/x",
            "/example.com/x",
            "1.2/notes.txt",
            "foo..com/x",
            "-bad.com/x",
            "example.com/has space",
        ] {
            let url = TerminalOpenURLResolver.resolve(raw, workingDirectory: "/repo", fileExists: { _ in false })
            XCTAssertTrue(url.isFileURL, "\(raw) resolved to \(url.absoluteString)")
        }
    }
}
