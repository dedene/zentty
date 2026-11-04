import Foundation
import XCTest
@testable import Zentty

/// Fake secrets are assembled at runtime so no literal token ever lands in the repository
/// (GitHub push protection scans for them).
final class AgentHistoryRedactorTests: XCTestCase {
    private let redactor = AgentHistoryRedactor.shared
    private let r = AgentHistoryRedactor.replacement

    private func body(_ count: Int, _ alphabet: String = "aB3dE5gH7jK9mN1pQ2") -> String {
        let characters = Array(alphabet)
        return String((0..<count).map { characters[$0 % characters.count] })
    }

    private func assertRedacted(
        _ secret: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(redactor.mayContainSecret("token \(secret) end"), file: file, line: line)
        XCTAssertEqual(redactor.redact("token \(secret) end"), "token \(r) end", file: file, line: line)
    }

    // MARK: - One test per pattern

    func test_pem_private_key() {
        let begin = "-----BEGIN " + "RSA PRIVATE KEY-----"
        let end = "-----END " + "RSA PRIVATE KEY-----"
        assertRedacted("\(begin)\nMIIEpAIBAAKCAQEA\nabcdef==\n\(end)")
    }

    func test_openai_and_anthropic_sk_keys() {
        assertRedacted("sk" + "-" + body(32))
        assertRedacted("sk" + "-proj-" + body(40))
        assertRedacted("sk" + "-ant-api03-" + body(40))
    }

    func test_github_tokens() {
        for prefix in ["p", "o", "u", "s", "r"] {
            assertRedacted("gh" + prefix + "_" + body(36))
        }
        assertRedacted("github" + "_pat_" + "11ABCDEFG_" + body(40))
    }

    func test_slack_tokens() {
        for kind in ["a", "b", "p", "r", "s"] {
            assertRedacted("xo" + "x\(kind)-" + "123456789012-" + body(24))
        }
    }

    func test_aws_access_key_ids() {
        assertRedacted("AK" + "IA" + "IOSFODNN7EXAMPLE")
        assertRedacted("AS" + "IA" + "IOSFODNN7EXAMPLE")
    }

    func test_jwt() {
        assertRedacted("ey" + "J" + body(20) + "." + "ey" + "J" + body(30) + "." + body(43))
    }

    func test_google_api_key() {
        assertRedacted("AI" + "za" + "Sy" + body(33))
    }

    func test_gitlab_token() {
        assertRedacted("gl" + "pat-" + body(20))
    }

    func test_stripe_keys() {
        assertRedacted("sk" + "_live_" + body(24))
        assertRedacted("sk" + "_test_" + body(24))
        assertRedacted("rk" + "_live_" + body(24))
        assertRedacted("rk" + "_test_" + body(24))
    }

    func test_npm_token() {
        assertRedacted("np" + "m_" + body(36))
    }

    // MARK: - Pattern edges

    func test_ghp_requires_length() {
        let short = "gh" + "p_" + body(19)
        XCTAssertEqual(redactor.redact("x \(short) y"), "x \(short) y")
        let long = "gh" + "p_" + body(20)
        XCTAssertEqual(redactor.redact("x \(long) y"), "x \(r) y")
        // The fixed precedence: the length requirement applies to every prefix, not only to
        // `github_pat_` (the spec's `ghp_|gho_|…` alternation matched a bare `ghp_`).
        XCTAssertEqual(redactor.redact("use gh" + "p_ prefix"), "use gh" + "p_ prefix")
        XCTAssertEqual(redactor.redact("the gh" + "s_ and gh" + "o_ prefixes"), "the gh" + "s_ and gh" + "o_ prefixes")
    }

    func test_pem_multiline_and_unterminated() {
        let begin = "-----BEGIN " + "OPENSSH PRIVATE KEY-----"
        let end = "-----END " + "OPENSSH PRIVATE KEY-----"
        let terminated = "before\n\(begin)\nb3BlbnNzaC1rZXktdjEAAAAA\nAAAABG5vbmUAAAAEbm9uZQ\n\(end)\nafter"
        XCTAssertEqual(redactor.redact(terminated), "before\n\(r)\nafter")

        let unterminated = "key:\n\(begin)\nb3BlbnNzaC1rZXktdjEAAAAA\ntruncated here"
        XCTAssertEqual(redactor.redact(unterminated), "key:\n\(r)")

        let twoKeys = "\(begin)\nAAAA\n\(end) and \(begin)\nBBBB\n\(end)"
        XCTAssertEqual(redactor.redact(twoKeys), "\(r) and \(r)")

        let plain = "-----BEGIN " + "PRIVATE KEY-----\nMIIE\n-----END " + "PRIVATE KEY-----"
        XCTAssertEqual(redactor.redact(plain), r)

        // A public key is not a secret.
        let publicKey = "-----BEGIN PUBLIC KEY-----\nMIIBIjAN\n-----END PUBLIC KEY-----"
        XCTAssertEqual(redactor.redact(publicKey), publicKey)
    }

    func test_bearer_keeps_prefix() {
        let token = body(32)
        XCTAssertEqual(
            redactor.redact("curl -H 'Authorization: Bearer \(token)' https://api"),
            "curl -H 'Authorization: Bearer \(r) https://api"
        )
        XCTAssertEqual(
            redactor.redact("authorization:bearer   \(token)"),
            "authorization:bearer   \(r)"
        )
        XCTAssertEqual(
            redactor.redact("AUTHORIZATION: BEARER \(token)"),
            "AUTHORIZATION: BEARER \(r)"
        )
        // Short values (placeholders) stay.
        XCTAssertEqual(redactor.redact("Authorization: Bearer $TOKEN"), "Authorization: Bearer $TOKEN")
    }

    func test_negatives_unchanged() {
        let texts = [
            "sk-abc",
            "task-force",
            "the risk-management-framework-document-v2 is ready",
            "AKIA is a prefix",
            "eyJhbGci.short.parts",
            "npm_config_cache",
            "xoxb-short",
            "sk_live_short",
            "Please refactor the parser and run the tests.",
            "Bearer tokens are explained in the docs.",
        ]
        for text in texts {
            XCTAssertEqual(redactor.redact(text), text, text)
        }
    }

    func test_multiple_secrets_in_one_text() {
        let github = "gh" + "p_" + body(36)
        let aws = "AK" + "IA" + "IOSFODNN7EXAMPLE"
        XCTAssertEqual(
            redactor.redact("GITHUB_TOKEN=\(github)\nAWS_ACCESS_KEY_ID=\(aws)\n"),
            "GITHUB_TOKEN=\(r)\nAWS_ACCESS_KEY_ID=\(r)\n"
        )
    }

    func test_idempotent() {
        let pem = "-----BEGIN " + "EC PRIVATE KEY-----\nAAAA\n-----END " + "EC PRIVATE KEY-----"
        let text = [
            "sk" + "-" + body(30),
            "gh" + "p_" + body(36),
            "Authorization: Bearer " + "ey" + "J" + body(20) + "." + body(20) + "." + body(20),
            pem,
            "glpat-" + body(20),
            "plain words",
        ].joined(separator: "\n")
        let once = redactor.redact(text)
        XCTAssertNotEqual(once, text)
        XCTAssertEqual(redactor.redact(once), once)
        XCTAssertFalse(redactor.mayContainSecret(r))
    }

    func test_fast_path_returns_input() {
        let text = "Refactor the history indexer, then run the tests.\nNo secrets here: 日本語 ✓"
        XCTAssertFalse(redactor.mayContainSecret(text))
        XCTAssertEqual(redactor.redact(text), text)
        XCTAssertEqual(redactor.redact(""), "")
        XCTAssertFalse(redactor.mayContainSecret(""))
    }

    func test_non_ascii_context_keeps_surrounding_text() {
        let secret = "sk" + "-" + body(24)
        XCTAssertEqual(redactor.redact("clé 🔑 \(secret) — fin"), "clé 🔑 \(r) — fin")
    }
}
