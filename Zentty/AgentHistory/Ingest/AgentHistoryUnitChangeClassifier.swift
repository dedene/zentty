import Darwin
import Foundation

/// Decides what happened to a plain file unit since its cursor was saved. Rules, in order:
/// 1. no cursor → `.new`; no current identity (file gone) → `.missing`
/// 2. rejected cursor: same dev/ino → `.unchanged`, else `.new`
/// 3. dev/ino differ (or no stored identity) → `.rewrite`
/// 4. file shorter than the read offset → `.rewrite`
/// 5. same size and mtime, and the read offset reached that size → `.unchanged`. A cursor
///    that stopped short (batch limit hit, then the app quit before the continuation ran)
///    falls through, so the rest of the file is read even if the agent never writes again.
/// 6. read offset > 0 and the bytes before it changed (fingerprint) → `.rewrite`
/// 7. otherwise → `.append(fromOffset: byteOffset, nextSeq:)` (a 0-byte append refreshes metadata)
///
/// `fingerprintAtCursor` is called at most once, and only for rule 6.
enum AgentHistoryUnitChangeClassifier {
    static func classify(
        cursor: AgentHistoryCursor?,
        current: AgentHistoryFileIdentity?,
        fingerprintAtCursor: () -> Int64?
    ) -> AgentHistoryUnitChange {
        guard let cursor else {
            return .new
        }
        guard let current else {
            return .missing
        }
        if cursor.isRejected {
            guard let stored = cursor.identity, sameFile(stored, current) else {
                return .new
            }
            return .unchanged
        }
        guard let stored = cursor.identity, sameFile(stored, current) else {
            return .rewrite
        }
        if current.size < cursor.byteOffset {
            return .rewrite
        }
        if current.size == stored.size, current.mtimeNs == stored.mtimeNs, cursor.byteOffset >= current.size {
            return .unchanged
        }
        if cursor.byteOffset > 0, fingerprintAtCursor() != cursor.fingerprint {
            return .rewrite
        }
        return .append(fromOffset: cursor.byteOffset, nextSeq: cursor.nextSeq)
    }

    private static func sameFile(_ lhs: AgentHistoryFileIdentity, _ rhs: AgentHistoryFileIdentity) -> Bool {
        lhs.dev == rhs.dev && lhs.ino == rhs.ino
    }
}

/// FNV-1a 64 over the up-to-4 KB window that ends at a cursor's byte offset. A changed window
/// means the file was rewritten in place (truncated and regrown past the old offset).
enum AgentHistoryFileFingerprint {
    static let windowBytes = 4096

    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    /// Hash of `[endOffset - min(4096, endOffset), endOffset)` read with `pread`. nil when the
    /// file cannot be opened or ends before `endOffset`; an `endOffset` of 0 hashes nothing.
    static func compute(path: String, endOffset: Int64) -> Int64? {
        guard endOffset >= 0 else {
            return nil
        }
        let length = Int(min(Int64(windowBytes), endOffset))
        let start = endOffset - Int64(length)
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            return nil
        }
        defer { close(descriptor) }

        var buffer = [UInt8](repeating: 0, count: length)
        let filled = buffer.withUnsafeMutableBytes { raw -> Int in
            var total = 0
            while total < length {
                let count = pread(descriptor, raw.baseAddress! + total, length - total, off_t(start) + off_t(total))
                if count > 0 {
                    total += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            return total
        }
        guard filled == length else {
            return nil
        }
        return hash(buffer)
    }

    static func hash<Bytes: Sequence>(_ bytes: Bytes) -> Int64 where Bytes.Element == UInt8 {
        var value = offsetBasis
        for byte in bytes {
            value ^= UInt64(byte)
            value = value &* prime
        }
        return Int64(bitPattern: value)
    }
}
