import Foundation

// MARK: - Offer model

/// An immutable, window-free view model derived from a single `pairing.offer`.
///
/// It produces the exact bytes the QR code encodes — a `pairing.offer` envelope
/// that matches the M0 wire schema — plus the paste-able manual fallback code and
/// the countdown/expiry state the pairing sheet renders. Kept detached from any
/// `NSView` so `ZenttyLogicTests` can exercise the offer lifecycle without a
/// window.
struct CompanionPairingOfferModel: Equatable {
    let offer: CompanionPairingOffer

    /// Canonical (sorted-key) JSON of the `pairing.offer` envelope. This is the
    /// string the QR image encodes and the phone decodes with the same
    /// `CompanionEnvelope` schema.
    let qrPayloadJSON: String

    /// base64url of the QR payload bytes: a single opaque string the user can
    /// type or paste on the phone when the camera can't read the code. LAN-only
    /// until the relay lands in M2, so it carries the whole offer verbatim.
    let manualCode: String

    /// `envelopeId` is injectable so tests get deterministic bytes; production
    /// mints a fresh id per offer.
    init(offer: CompanionPairingOffer, envelopeId: String = UUID().uuidString) {
        self.offer = offer
        let envelope = CompanionEnvelope(id: envelopeId, message: .pairingOffer(offer))
        let data = Self.canonicalJSONData(for: envelope)
        self.qrPayloadJSON = String(decoding: data, as: UTF8.self)
        self.manualCode = CompanionBase64URL.encode(data)
    }

    /// The offer's absolute expiry, converted from the wire's ms-epoch integer.
    var expiresAt: Date {
        Date(timeIntervalSince1970: Double(offer.expiresAt) / 1000)
    }

    func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt
    }

    /// Whole seconds until expiry, clamped at zero. Rounds up so a countdown
    /// shows "0:01" for the final fractional second rather than snapping to zero.
    func remainingSeconds(now: Date = Date()) -> Int {
        max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
    }

    /// `m:ss` countdown text, e.g. "1:59".
    func countdownText(now: Date = Date()) -> String {
        let total = remainingSeconds(now: now)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func canonicalJSONData(for envelope: CompanionEnvelope) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // The envelope encodes deterministically; the only failure mode would be a
        // non-conforming payload, which the type system rules out here.
        return (try? encoder.encode(envelope)) ?? Data("{}".utf8)
    }
}

// MARK: - Pairing session

/// Owns the currently displayed offer and re-mints it when it expires. The mint
/// closure is injected so the pairing sheet can wire it to the live bridge while
/// tests drive it with a deterministic stub — no window, no sockets.
final class CompanionPairingSession {
    private let mint: () -> CompanionPairingOffer
    private(set) var current: CompanionPairingOfferModel

    init(mint: @escaping () -> CompanionPairingOffer) {
        self.mint = mint
        self.current = CompanionPairingOfferModel(offer: mint())
    }

    /// Re-mints a fresh offer when the current one has expired. Returns `true`
    /// when it regenerated, so the caller can refresh the QR image and countdown.
    @discardableResult
    func regenerateIfExpired(now: Date = Date()) -> Bool {
        guard current.isExpired(now: now) else { return false }
        current = CompanionPairingOfferModel(offer: mint())
        return true
    }

    /// Unconditionally mints a fresh offer (e.g. the sheet was re-opened).
    func regenerate() {
        current = CompanionPairingOfferModel(offer: mint())
    }
}

// MARK: - Paired device row

/// Display strings for one paired-device row, formatted off the main thread's
/// critical path and independent of any view, so the list rendering stays
/// testable and the formatting logic lives in one place.
struct CompanionPairedDeviceRow: Equatable {
    let deviceId: String
    let name: String
    let pairedAtText: String
    let lastSeenText: String

    init(device: CompanionPairedDevice, now: Date = Date()) {
        self.deviceId = device.deviceId
        self.name = device.name.isEmpty ? "Unnamed device" : device.name

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        self.pairedAtText = "Paired \(dateFormatter.string(from: device.pairedAt))"

        if now.timeIntervalSince(device.lastSeenAt) < 60 {
            self.lastSeenText = "Last seen just now"
        } else {
            let relativeFormatter = RelativeDateTimeFormatter()
            relativeFormatter.unitsStyle = .full
            self.lastSeenText = "Last seen \(relativeFormatter.localizedString(for: device.lastSeenAt, relativeTo: now))"
        }
    }
}
