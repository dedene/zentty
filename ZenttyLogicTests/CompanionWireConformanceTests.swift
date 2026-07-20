import XCTest
@testable import Zentty

/// Conformance tests driven by the shared wire vectors in
/// `companion/wire/vectors/*.json`. Every vector case is either a valid message
/// (must decode, and must survive a decode → encode → decode → encode round trip
/// with stable canonical JSON) or an invalid message (must fail to decode).
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
    }

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

    private func loadCases() throws -> [VectorCase] {
        let urls = try vectorFileURLs()
        XCTAssertEqual(urls.count, 32, "expected 32 vector files, found \(urls.count)")

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
                    let message = entry["message"]
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
                        messageData: messageData
                    )
                )
            }
        }
        return cases
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

    // MARK: - Tests

    func testAllVectorsRoundTrip() throws {
        let cases = try loadCases()
        XCTAssertGreaterThanOrEqual(cases.count, 32, "expected at least one case per file")

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
        let urls = try vectorFileURLs()
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
        XCTAssertEqual(names, expected, "vector files do not match the known message families")
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
}
