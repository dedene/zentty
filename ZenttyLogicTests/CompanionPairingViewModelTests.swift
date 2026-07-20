import XCTest
@testable import Zentty

/// Detached (window-free) tests for the Mobile Devices pairing view models: the
/// offer → QR payload encoding (asserted against the shared M0 `pairing.offer`
/// wire vector), the expiry/countdown math, and the session's regenerate-on-expiry
/// behaviour.
final class CompanionPairingViewModelTests: XCTestCase {

    // MARK: - Fixtures

    /// Mirrors the "full offer with lan hint" case in
    /// `companion/wire/vectors/pairing.offer.json`.
    private func vectorOffer() -> CompanionPairingOffer {
        CompanionPairingOffer(
            relayUrl: "wss://relay.zenjoy.be",
            lanHint: CompanionLanHint(host: "192.168.1.24", port: 51820),
            macDeviceId: "k5tR2xQb9m8Zv1Hc7Lp0Wd3Nf6Ay4Ej8Tg2Uh5Ki0",
            macPubKey: "MCowBQYDK2VwAyEA6f1b3d2a9c474e188a521d7f0b6c3e94aa",
            secret: "n3Qx7Kp2Wm9Zb4Hs1Vd8Rf5",
            expiresAt: 1784601600000
        )
    }

    private let vectorEnvelopeId = "6f1b3d2a-9c47-4e18-8a52-1d7f0b6c3e94"

    private func canonical(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }

    // MARK: - QR payload matches the wire schema

    func testQRPayloadDecodesToPairingOfferEnvelope() throws {
        let model = CompanionPairingOfferModel(offer: vectorOffer(), envelopeId: vectorEnvelopeId)

        let envelope = try JSONDecoder().decode(
            CompanionEnvelope.self,
            from: Data(model.qrPayloadJSON.utf8)
        )
        XCTAssertEqual(envelope.type, "pairing.offer")
        XCTAssertEqual(envelope.v, CompanionProtocol.version)
        XCTAssertEqual(envelope.id, vectorEnvelopeId)
        guard case .pairingOffer(let decoded) = envelope.message else {
            return XCTFail("expected .pairingOffer, got \(envelope.message)")
        }
        XCTAssertEqual(decoded, vectorOffer())
    }

    func testQRPayloadCanonicalizesToM0Vector() throws {
        let model = CompanionPairingOfferModel(offer: vectorOffer(), envelopeId: vectorEnvelopeId)

        // The QR envelope must be byte-identical (by canonical JSON) to the shared
        // M0 vector's message, proving the QR speaks the exact pairing.offer schema.
        let vectorMessage = try loadPairingOfferVectorMessage()
        XCTAssertEqual(
            try canonical(Data(model.qrPayloadJSON.utf8)),
            try canonical(vectorMessage),
            "QR payload JSON diverges from the M0 pairing.offer vector schema"
        )
    }

    func testManualCodeRoundTripsToPayload() throws {
        let model = CompanionPairingOfferModel(offer: vectorOffer(), envelopeId: vectorEnvelopeId)
        let decoded = try XCTUnwrap(CompanionBase64URL.decode(model.manualCode))
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), model.qrPayloadJSON)
    }

    // MARK: - Expiry / countdown

    func testExpiryAndCountdown() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let offer = CompanionPairingOffer(
            relayUrl: "",
            lanHint: nil,
            macDeviceId: "d",
            macPubKey: "k",
            secret: "s",
            expiresAt: Int((base.timeIntervalSince1970 + 90) * 1000)
        )
        let model = CompanionPairingOfferModel(offer: offer)

        XCTAssertFalse(model.isExpired(now: base))
        XCTAssertEqual(model.remainingSeconds(now: base), 90)
        XCTAssertEqual(model.countdownText(now: base), "1:30")

        let atExpiry = base.addingTimeInterval(90)
        XCTAssertTrue(model.isExpired(now: atExpiry))
        XCTAssertEqual(model.remainingSeconds(now: atExpiry), 0)
        XCTAssertEqual(model.countdownText(now: atExpiry), "0:00")

        let past = base.addingTimeInterval(120)
        XCTAssertTrue(model.isExpired(now: past))
        XCTAssertEqual(model.remainingSeconds(now: past), 0)
    }

    // MARK: - Session regeneration

    func testSessionRegeneratesOnlyWhenExpired() {
        let base = Date(timeIntervalSince1970: 2_000_000)
        var mintCount = 0
        // Each mint issues a distinct secret and a 60s window from `base`.
        let session = CompanionPairingSession(mint: {
            mintCount += 1
            return CompanionPairingOffer(
                relayUrl: "",
                lanHint: nil,
                macDeviceId: "d",
                macPubKey: "k",
                secret: "secret-\(mintCount)",
                expiresAt: Int((base.timeIntervalSince1970 + 60) * 1000)
            )
        })

        XCTAssertEqual(mintCount, 1, "constructing the session mints the first offer")
        XCTAssertEqual(session.current.offer.secret, "secret-1")

        // Still valid → no regeneration.
        XCTAssertFalse(session.regenerateIfExpired(now: base.addingTimeInterval(30)))
        XCTAssertEqual(session.current.offer.secret, "secret-1")
        XCTAssertEqual(mintCount, 1)

        // Expired → regenerates a fresh, distinct offer.
        XCTAssertTrue(session.regenerateIfExpired(now: base.addingTimeInterval(61)))
        XCTAssertEqual(session.current.offer.secret, "secret-2")
        XCTAssertEqual(mintCount, 2)

        // Forced regeneration always mints.
        session.regenerate()
        XCTAssertEqual(session.current.offer.secret, "secret-3")
        XCTAssertEqual(mintCount, 3)
    }

    // MARK: - Paired device row

    func testPairedDeviceRowFormatting() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let recent = CompanionPairedDevice(
            deviceId: "id-1",
            publicKey: "pk",
            name: "Peter's iPhone",
            pairedAt: now.addingTimeInterval(-3600),
            lastSeenAt: now.addingTimeInterval(-10)
        )
        let row = CompanionPairedDeviceRow(device: recent, now: now)
        XCTAssertEqual(row.deviceId, "id-1")
        XCTAssertEqual(row.name, "Peter's iPhone")
        XCTAssertTrue(row.pairedAtText.hasPrefix("Paired "))
        XCTAssertEqual(row.lastSeenText, "Last seen just now")

        let unnamed = CompanionPairedDevice(
            deviceId: "id-2",
            publicKey: "pk",
            name: "",
            pairedAt: now.addingTimeInterval(-7200),
            lastSeenAt: now.addingTimeInterval(-7200)
        )
        let unnamedRow = CompanionPairedDeviceRow(device: unnamed, now: now)
        XCTAssertEqual(unnamedRow.name, "Unnamed device")
        XCTAssertTrue(unnamedRow.lastSeenText.hasPrefix("Last seen "))
        XCTAssertNotEqual(unnamedRow.lastSeenText, "Last seen just now")
    }

    // MARK: - Vector loading

    private func loadPairingOfferVectorMessage() throws -> Data {
        let bundle = Bundle(for: type(of: self))
        var url = bundle.url(forResource: "pairing.offer", withExtension: "json", subdirectory: "vectors")
        if url == nil, let resourceURL = bundle.resourceURL {
            let candidate = resourceURL
                .appendingPathComponent("vectors", isDirectory: true)
                .appendingPathComponent("pairing.offer.json")
            if FileManager.default.fileExists(atPath: candidate.path) { url = candidate }
        }
        let vectorURL = try XCTUnwrap(url, "pairing.offer.json vector not found in test bundle")
        let data = try Data(contentsOf: vectorURL)
        let array = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let firstMessage = try XCTUnwrap(array.first?["message"])
        return try JSONSerialization.data(withJSONObject: firstMessage, options: [.fragmentsAllowed])
    }
}
