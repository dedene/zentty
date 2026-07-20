import CryptoKit
import XCTest
@testable import Zentty

/// Conformance tests driven by the shared wire vectors in
/// `companion/wire/vectors/*.json`. Two lanes:
///
/// - `relay.*.json` files carry flat RELAY TRANSPORT frames (`CompanionRelayFrame`,
///   see `CompanionRelayFrames.swift`) — the plaintext device↔relay handshake, no
///   `v`/`id`/`payload` envelope.
/// - Every other file carries an E2E `{v, id, type, payload}` envelope
///   (`CompanionEnvelope`).
///
/// Within each lane every case is either a valid message (must decode, and must
/// survive a decode → encode → decode → encode round trip with stable canonical
/// JSON) or an invalid message (must fail to decode).
///
/// The TypeScript `@zentty/wire` suite consumes the same files, so both sides
/// agree byte-for-byte on the contract (compared by sorted-key canonical JSON,
/// never raw string equality — key order differs across languages).
final class CompanionWireConformanceTests: XCTestCase {

    private struct VectorCase {
        let file: String
        let name: String
        let valid: Bool
        let messageData: Data
        let rawMessage: [String: Any]
    }

    private static let expectedEnvelopeFileCount = 32
    private static let expectedRelayFileCount = 8

    // MARK: - Loading

    private func vectorFileURLs() throws -> [URL] {
        let bundle = Bundle(for: type(of: self))
        if let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: "vectors"),
           !urls.isEmpty {
            return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        // Fallback: some copy phases flatten the folder into the bundle root.
        if let resourceURL = bundle.resourceURL {
            let dir = resourceURL.appendingPathComponent("vectors", isDirectory: true)
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ) {
                let jsons = contents.filter { $0.pathExtension == "json" }
                if !jsons.isEmpty {
                    return jsons.sorted { $0.lastPathComponent < $1.lastPathComponent }
                }
            }
        }
        return []
    }

    /// `true` for `relay.*.json` — the flat transport-frame lane.
    private func isRelayVectorFile(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.hasPrefix("relay.")
    }

    private func loadCases(from urls: [URL]) throws -> [VectorCase] {
        var cases: [VectorCase] = []
        for url in urls {
            let data = try Data(contentsOf: url)
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                XCTFail("vector file \(url.lastPathComponent) is not an array of objects")
                continue
            }
            for entry in array {
                guard
                    let name = entry["name"] as? String,
                    let valid = entry["valid"] as? Bool,
                    let message = entry["message"] as? [String: Any]
                else {
                    XCTFail("malformed case in \(url.lastPathComponent): \(entry)")
                    continue
                }
                let messageData = try JSONSerialization.data(
                    withJSONObject: message,
                    options: [.fragmentsAllowed]
                )
                cases.append(
                    VectorCase(
                        file: url.lastPathComponent,
                        name: name,
                        valid: valid,
                        messageData: messageData,
                        rawMessage: message
                    )
                )
            }
        }
        return cases
    }

    private func loadEnvelopeCases() throws -> [VectorCase] {
        let urls = try vectorFileURLs().filter { !isRelayVectorFile($0) }
        XCTAssertEqual(
            urls.count,
            Self.expectedEnvelopeFileCount,
            "expected \(Self.expectedEnvelopeFileCount) envelope vector files, found \(urls.count)"
        )
        return try loadCases(from: urls)
    }

    private func loadRelayCases() throws -> [VectorCase] {
        let urls = try vectorFileURLs().filter { isRelayVectorFile($0) }
        XCTAssertEqual(
            urls.count,
            Self.expectedRelayFileCount,
            "expected \(Self.expectedRelayFileCount) relay vector files, found \(urls.count)"
        )
        return try loadCases(from: urls)
    }

    // MARK: - Canonicalization

    /// Sorted-key canonical bytes, so comparisons ignore field ordering.
    private func canonical(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .fragmentsAllowed]
        )
    }

    // MARK: - Envelope lane

    func testAllVectorsRoundTrip() throws {
        let cases = try loadEnvelopeCases()
        XCTAssertGreaterThanOrEqual(cases.count, Self.expectedEnvelopeFileCount, "expected at least one case per file")

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        for vector in cases {
            let label = "\(vector.file) — \(vector.name)"
            if vector.valid {
                let envelope: CompanionEnvelope
                do {
                    envelope = try decoder.decode(CompanionEnvelope.self, from: vector.messageData)
                } catch {
                    XCTFail("valid vector failed to decode [\(label)]: \(error)")
                    continue
                }

                do {
                    let encoded1 = try encoder.encode(envelope)
                    let redecoded = try decoder.decode(CompanionEnvelope.self, from: encoded1)
                    let encoded2 = try encoder.encode(redecoded)

                    XCTAssertEqual(
                        envelope,
                        redecoded,
                        "decoded value not stable across round trip [\(label)]"
                    )
                    XCTAssertEqual(
                        try canonical(encoded1),
                        try canonical(encoded2),
                        "canonical JSON not stable across round trip [\(label)]"
                    )
                } catch {
                    XCTFail("valid vector failed to round trip [\(label)]: \(error)")
                }
            } else {
                XCTAssertThrowsError(
                    try decoder.decode(CompanionEnvelope.self, from: vector.messageData),
                    "invalid vector should have failed to decode [\(label)]"
                )
            }
        }
    }

    /// Every known message family is represented by at least one vector file,
    /// so the round-trip test above actually exercises each `type`.
    func testVectorCoverage() throws {
        let urls = try vectorFileURLs().filter { !isRelayVectorFile($0) }
        let names = Set(urls.map { $0.deletingPathExtension().lastPathComponent })
        let expected: Set<String> = [
            "pairing.offer", "pairing.request", "pairing.confirm", "pairing.reject",
            "session.hello", "session.ready", "session.ping", "session.pong", "session.error",
            "dashboard.subscribe", "dashboard.snapshot", "dashboard.delta",
            "pane.watch", "pane.unwatch", "pane.text", "pane.scrollback",
            "input.text", "input.key", "input.quickAction", "input.ack",
            "transcript.subscribe", "transcript.snapshot", "transcript.delta", "transcript.unavailable",
            "lease.request", "lease.grant", "lease.heartbeat", "lease.resize", "lease.release", "lease.revoked",
            "push.register", "push.test"
        ]
        XCTAssertEqual(names, expected, "envelope vector files do not match the known message families")
    }

    /// An unknown `type` must decode to `.unsupported` (carrying the raw payload)
    /// rather than throwing, and must survive a round trip.
    func testUnknownTypeDecodesToUnsupported() throws {
        let json = """
        {
          "v": 1,
          "id": "00000000-0000-4000-8000-000000000000",
          "type": "pane.teleport",
          "payload": { "paneId": "pn_x", "warp": 9, "nested": { "a": [1, 2, 3] } }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        let envelope = try decoder.decode(CompanionEnvelope.self, from: json)
        guard case .unsupported(let type, _) = envelope.message else {
            return XCTFail("unknown type should decode to .unsupported, got \(envelope.message)")
        }
        XCTAssertEqual(type, "pane.teleport")

        let encoded1 = try encoder.encode(envelope)
        let redecoded = try decoder.decode(CompanionEnvelope.self, from: encoded1)
        let encoded2 = try encoder.encode(redecoded)
        XCTAssertEqual(envelope, redecoded)
        XCTAssertEqual(try canonical(encoded1), try canonical(encoded2))
        // The unknown payload survived the round trip intact.
        XCTAssertEqual(try canonical(json), try canonical(encoded1))
    }

    // MARK: - Relay transport lane

    func testAllRelayVectorsRoundTrip() throws {
        let cases = try loadRelayCases()
        XCTAssertGreaterThanOrEqual(cases.count, Self.expectedRelayFileCount, "expected at least one case per file")

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        for vector in cases {
            let label = "\(vector.file) — \(vector.name)"
            if vector.valid {
                let frame: CompanionRelayFrame
                do {
                    frame = try decoder.decode(CompanionRelayFrame.self, from: vector.messageData)
                } catch {
                    XCTFail("valid relay vector failed to decode [\(label)]: \(error)")
                    continue
                }

                do {
                    let encoded1 = try encoder.encode(frame)
                    let redecoded = try decoder.decode(CompanionRelayFrame.self, from: encoded1)
                    let encoded2 = try encoder.encode(redecoded)

                    XCTAssertEqual(
                        frame,
                        redecoded,
                        "decoded value not stable across round trip [\(label)]"
                    )
                    XCTAssertEqual(
                        try canonical(encoded1),
                        try canonical(encoded2),
                        "canonical JSON not stable across round trip [\(label)]"
                    )
                } catch {
                    XCTFail("valid relay vector failed to round trip [\(label)]: \(error)")
                }
            } else {
                XCTAssertThrowsError(
                    try decoder.decode(CompanionRelayFrame.self, from: vector.messageData),
                    "invalid relay vector should have failed to decode [\(label)]"
                )
            }
        }
    }

    /// Every registered relay frame type is represented by at least one vector
    /// file, so the round-trip test above actually exercises each `type`.
    func testRelayVectorCoverage() throws {
        let urls = try vectorFileURLs().filter { isRelayVectorFile($0) }
        let names = Set(urls.map { $0.deletingPathExtension().lastPathComponent })
        let expected: Set<String> = [
            CompanionRelayFrame.challengeType,
            CompanionRelayFrame.authType,
            CompanionRelayFrame.readyType,
            CompanionRelayFrame.deniedType,
            CompanionRelayFrame.frameType,
            CompanionRelayFrame.peerStatusType,
            CompanionRelayFrame.watchType,
            CompanionRelayFrame.errorType,
        ]
        XCTAssertEqual(names, expected, "relay vector files do not match the known relay frame types")
    }

    /// An unknown relay `type` must fail to decode (unlike the envelope lane,
    /// the relay transport has no `.unsupported` forward-compat case: the relay
    /// server and every device build share one closed frame set).
    func testUnknownRelayTypeFailsToDecode() throws {
        let json = """
        { "type": "relay.teleport", "paneId": "pn_x" }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(CompanionRelayFrame.self, from: json)) { error in
            guard let unknown = error as? CompanionRelayFrame.UnknownFrameTypeError else {
                return XCTFail("expected UnknownFrameTypeError, got \(error)")
            }
            XCTAssertEqual(unknown.type, "relay.teleport")
        }
    }

    /// Interop check: `relay.auth.json`'s valid case carries a *real* Ed25519
    /// signature generated by Node (see `companion/relay/test/crypto.test.ts`,
    /// which freezes the exact same fixture). Decode it through
    /// `CompanionRelayFrame` and independently verify the signature with
    /// CryptoKit, over the same bytes the relay's `verifyRelayAuth` checks:
    /// UTF-8 `"zentty-relay-auth:" + nonce`, where `nonce` is the *base64url
    /// string* exactly as sent in `relay.challenge` — not its decoded bytes.
    /// `relay.challenge.json`'s valid case nonce is that same frozen nonce.
    ///
    /// Note: this deliberately does NOT use `CompanionRelayAuthProof.message`,
    /// which signs over the *decoded* nonce bytes — a real cross-language
    /// mismatch with the relay's `verifyRelayAuth` (see
    /// `companion/relay/src/crypto.ts`). That mismatch was confirmed directly
    /// against this vector's signature: the decoded-bytes form does not
    /// verify, only the string form does. Left unfixed here since it's a
    /// production auth-handshake behavior change, out of scope for a
    /// conformance-suite fix — flagged for a follow-up.
    func testRelayAuthVectorInteropSignature() throws {
        let cases = try loadRelayCases()

        guard let authVector = cases.first(where: { $0.file == "relay.auth.json" && $0.valid }) else {
            XCTFail("expected a valid case in relay.auth.json")
            return
        }
        guard let challengeVector = cases.first(where: { $0.file == "relay.challenge.json" && $0.valid }) else {
            XCTFail("expected a valid case in relay.challenge.json")
            return
        }

        let frame = try JSONDecoder().decode(CompanionRelayFrame.self, from: authVector.messageData)
        guard case .auth(let auth) = frame else {
            return XCTFail("relay.auth.json valid case did not decode to .auth")
        }

        guard let nonce = challengeVector.rawMessage["nonce"] as? String else {
            XCTFail("relay.challenge.json valid case is missing nonce")
            return
        }

        guard
            let pubKeyBytes = CompanionBase64URL.decode(auth.pubKey),
            let sigBytes = CompanionBase64URL.decode(auth.sig)
        else {
            XCTFail("relay.auth.json valid case has malformed base64url fields")
            return
        }

        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: pubKeyBytes)
        let message = Data((CompanionRelayAuthProof.label + nonce).utf8)

        XCTAssertTrue(
            publicKey.isValidSignature(sigBytes, for: message),
            "relay.auth.json vector signature failed CryptoKit verification"
        )
        XCTAssertEqual(auth.deviceId, auth.pubKey, "deviceId must equal base64url(pubKey)")
    }
}
