import Foundation

// MARK: - pane.bytes.*

/// The raw PTY byte lane (cmux-style streaming) — the high-fidelity sibling of
/// the plain-text `pane.*` lane in `CompanionPane.swift`. Where `pane.text`
/// ships a debounced re-rendered viewport, this lane forwards the terminal's
/// raw output bytes so the phone drives a real VT emulator locally.
///
/// Sequencing: `epoch` is an opaque string minted once per surface lifetime and
/// changes on surface restart (phone resets its emulator and cold-attaches).
/// `seq` is the BYTE OFFSET of a chunk's first byte within its epoch, advancing
/// by the decoded byte length of each chunk. The phone detects loss when an
/// incoming `seq` != its expected offset and recovers via a warm re-attach.
/// `lastSeq` on warm attach is an EXCLUSIVE resume cursor — the first missing
/// byte offset (phone's next expected), not the last included index.
///
/// Binary fields (`replay`, `data`) are STANDARD base64 (matching the push seal
/// and pairing DER keys), NOT base64url. The charset/length bounds are validated
/// on the TypeScript (`@zentty/wire`) side; the Swift mirror carries the encoded
/// string verbatim, consistent with how the other payloads treat wire strings.

/// `pane.bytes.attach` (phone → mac). Request half; the reply is
/// `CompanionPaneBytesAttached`, correlated via the envelope `replyTo` (same
/// machinery as `pane.scrollback`). Cold attach omits both `lastSeq` and `epoch`;
/// a warm re-attach carries both — `lastSeq` is the exclusive next expected
/// offset and `epoch` is the epoch that cursor belongs to.
///
/// Partial warm shapes (only one of `lastSeq`/`epoch`) fail decoding so Swift
/// matches the Zod `superRefine` on `@zentty/wire`.
struct CompanionPaneBytesAttach: CompanionMessagePayload {
    static let messageType = "pane.bytes.attach"

    var paneId: String
    var lastSeq: Int?
    var epoch: String?

    enum CodingKeys: String, CodingKey {
        case paneId, lastSeq, epoch
    }

    init(paneId: String, lastSeq: Int? = nil, epoch: String? = nil) {
        self.paneId = paneId
        self.lastSeq = lastSeq
        self.epoch = epoch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneId = try container.decode(String.self, forKey: .paneId)
        lastSeq = try container.decodeIfPresent(Int.self, forKey: .lastSeq)
        epoch = try container.decodeIfPresent(String.self, forKey: .epoch)
        let hasLast = lastSeq != nil
        let hasEpoch = epoch != nil
        guard hasLast == hasEpoch else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "warm attach requires both lastSeq and epoch; cold attach omits both"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(paneId, forKey: .paneId)
        try container.encodeIfPresent(lastSeq, forKey: .lastSeq)
        try container.encodeIfPresent(epoch, forKey: .epoch)
    }
}

/// `pane.bytes.attached` (mac → phone). Reply half of `pane.bytes.attach`,
/// carried with `replyTo` = the attach frame's envelope `id`.
///
/// `startSeq` is the byte offset of the first byte in `replay`; subsequent chunk
/// `seq` values continue from `startSeq + decoded(replay)`. `replay` may be empty
/// (`""`). `truncated == true` means the ring could not cover the requested
/// resume point, so the phone MUST reset its emulator before writing `replay`.
struct CompanionPaneBytesAttached: CompanionMessagePayload {
    static let messageType = "pane.bytes.attached"

    var paneId: String
    var epoch: String
    var startSeq: Int
    var replay: String
    var truncated: Bool
    /// Self-contained VT byte stream reproducing the pane's screen, base64.
    /// Present on cold attach; a raw byte tail alone cannot rebuild a TUI screen.
    /// The phone resets, sizes to `snapshotCols`×`snapshotRows`, writes this,
    /// then writes `replay`. Excluded from seq arithmetic — `startSeq` still
    /// describes `replay`'s first byte only.
    var snapshot: String?
    /// The mac's grid at capture time. The mac is authoritative for grid size on
    /// this lane, so these are an instruction to the phone, not a hint.
    var snapshotRows: Int?
    var snapshotCols: Int?

    init(
        paneId: String,
        epoch: String,
        startSeq: Int,
        replay: String,
        truncated: Bool,
        snapshot: String? = nil,
        snapshotRows: Int? = nil,
        snapshotCols: Int? = nil
    ) {
        self.paneId = paneId
        self.epoch = epoch
        self.startSeq = startSeq
        self.replay = replay
        self.truncated = truncated
        self.snapshot = snapshot
        self.snapshotRows = snapshotRows
        self.snapshotCols = snapshotCols
    }
}

/// `pane.bytes.chunk` (mac → phone). One run of raw PTY output. `seq` is the byte
/// offset of `data`'s first byte within `epoch`; `data` is standard base64.
struct CompanionPaneBytesChunk: CompanionMessagePayload {
    static let messageType = "pane.bytes.chunk"

    var paneId: String
    var epoch: String
    var seq: Int
    var data: String
}

/// `pane.bytes.detach` (phone → mac). Stop streaming this pane's byte lane.
struct CompanionPaneBytesDetach: CompanionMessagePayload {
    static let messageType = "pane.bytes.detach"

    var paneId: String
}
