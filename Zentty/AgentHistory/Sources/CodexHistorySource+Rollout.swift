import Foundation

/// Per-rollout state carried in `cursor.adapterState` between batches.
struct CodexRolloutState: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case jsonl
        case zst
    }

    static let maxPendingCommitCalls = 32

    /// The form of the file `byteOffset` was measured in (decompressed bytes for `.zst`).
    var lastKind: Kind
    /// The last batch read to the end of the file.
    var reachedEOF = false
    /// Canonical, from the authoritative `session_meta`.
    var cwd: String?
    var branch: String?
    /// Latest `turn_context` values.
    var model: String?
    var effort: String?
    var startedAtMs: Int64?
    /// Timestamp of the last record read; stands in for records without one.
    var lastAtMs: Int64?
    var isChild = false
    /// Tool calls that ran `git commit` and whose output has not been seen yet.
    var pendingCommitCallIDs: [String] = []
    /// The file the last batch read. A rollout moved to `archived_sessions/` (or back), or
    /// swapped for its `.zst`, keeps its content; a different path is what tells the classifier
    /// that the stored transcript path and archive flag need a refresh.
    var path: String?

    init(lastKind: Kind) {
        self.lastKind = lastKind
    }

    private enum CodingKeys: String, CodingKey {
        case lastKind, reachedEOF, cwd, branch, model, effort, startedAtMs, lastAtMs, isChild, pendingCommitCallIDs, path
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastKind = try container.decodeIfPresent(Kind.self, forKey: .lastKind) ?? .jsonl
        reachedEOF = try container.decodeIfPresent(Bool.self, forKey: .reachedEOF) ?? false
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        startedAtMs = try container.decodeIfPresent(Int64.self, forKey: .startedAtMs)
        lastAtMs = try container.decodeIfPresent(Int64.self, forKey: .lastAtMs)
        isChild = try container.decodeIfPresent(Bool.self, forKey: .isChild) ?? false
        pendingCommitCallIDs = try container.decodeIfPresent([String].self, forKey: .pendingCommitCallIDs) ?? []
        path = try container.decodeIfPresent(String.self, forKey: .path)
    }

    static func decode(_ data: Data?) -> CodexRolloutState? {
        guard let data else {
            return nil
        }
        return try? JSONDecoder().decode(CodexRolloutState.self, from: data)
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

/// A byte source that remembers the last `capacity` bytes it delivered, so the decompressed
/// fingerprint window before a `.zstdJSONL` cursor (A-5) is computed without decompressing the
/// file a second time.
final class CodexWindowRecordingSource: AgentHistoryByteSource {
    private let base: AgentHistoryByteSource
    private let capacity: Int
    private var ring: [UInt8]
    private var filled = 0
    /// Absolute offset just past the last delivered byte.
    private(set) var endOffset: Int64

    init(base: AgentHistoryByteSource, startOffset: Int64, capacity: Int) {
        self.base = base
        self.capacity = max(capacity, AgentHistoryFileFingerprint.windowBytes)
        self.ring = [UInt8](repeating: 0, count: self.capacity)
        self.endOffset = startOffset
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = try base.read(into: buffer)
        if count > 0 {
            record(UnsafeRawBufferPointer(rebasing: buffer[0 ..< count]))
        }
        return count
    }

    /// Reads and drops `count` bytes, recording them (primes the window before a resume offset).
    func discard(_ count: Int64) throws {
        var remaining = count
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        while remaining > 0 {
            let length = Int(min(remaining, Int64(scratch.count)))
            let delivered = try scratch.withUnsafeMutableBytes { raw in
                try read(into: UnsafeMutableRawBufferPointer(rebasing: raw[0 ..< length]))
            }
            if delivered == 0 {
                throw ZstdByteSource.Failure.unexpectedEOF
            }
            remaining -= Int64(delivered)
        }
    }

    /// `AgentHistoryFileFingerprint.hash` of `[end - min(4096, end), end)`; nil when those bytes
    /// are no longer (or not yet) in the window.
    func fingerprint(endOffset end: Int64) -> Int64? {
        let length = Int(min(Int64(AgentHistoryFileFingerprint.windowBytes), end))
        let start = end - Int64(length)
        guard end <= endOffset, start >= endOffset - Int64(filled) else {
            return nil
        }
        var window = [UInt8]()
        window.reserveCapacity(length)
        var offset = start
        while offset < end {
            window.append(ring[Int(offset % Int64(capacity))])
            offset += 1
        }
        return AgentHistoryFileFingerprint.hash(window)
    }

    private func record(_ bytes: UnsafeRawBufferPointer) {
        let kept = bytes.count > capacity ? UnsafeRawBufferPointer(rebasing: bytes[(bytes.count - capacity)...]) : bytes
        let skipped = Int64(bytes.count - kept.count)
        var position = Int((endOffset + skipped) % Int64(capacity))
        var index = 0
        while index < kept.count {
            let run = min(capacity - position, kept.count - index)
            ring.withUnsafeMutableBytes { destination in
                destination.baseAddress!.advanced(by: position)
                    .copyMemory(from: kept.baseAddress!.advanced(by: index), byteCount: run)
            }
            index += run
            position = (position + run) % capacity
        }
        endOffset += Int64(bytes.count)
        filled = min(capacity, filled + bytes.count)
    }
}

/// A decompressing reader parked between batches of one compressed rollout.
final class CodexZstdContinuation {
    let key: String
    let identity: AgentHistoryFileIdentity
    /// Decompressed offset the reader's next line starts at.
    let offset: Int64
    let reader: JSONLTailReader
    let window: CodexWindowRecordingSource

    init(key: String, identity: AgentHistoryFileIdentity, offset: Int64, reader: JSONLTailReader, window: CodexWindowRecordingSource) {
        self.key = key
        self.identity = identity
        self.offset = offset
        self.reader = reader
        self.window = window
    }
}

extension CodexHistorySource {
    static let readerChunkSize = 1 << 18
    /// Covers a full reader chunk plus the fingerprint window behind it.
    static let windowCapacity = readerChunkSize + 2 * AgentHistoryFileFingerprint.windowBytes

    /// One batch of a rollout. The thread id comes from the file name; metadata from the catalog
    /// row when there is one, else from the authoritative `session_meta` (the record whose
    /// `payload.id` is this thread: subagent rollouts also carry their parent's).
    func ingestRollout(
        unit: AgentHistoryUnit,
        cursor: AgentHistoryCursor?,
        mode: AgentHistoryIngestMode,
        context: AgentHistoryIngestContext
    ) throws -> AgentHistoryIngestBatch {
        guard let identity = AgentHistoryFileIdentity.stat(path: unit.path) else {
            throw POSIXError(.ENOENT)
        }
        let kind: CodexRolloutState.Kind = unit.kind == .zstdJSONL ? .zst : .jsonl
        let base = cursor ?? AgentHistoryCursor(sourceID: 0, unitKey: unit.key)
        let startOffset: Int64
        let firstSeq: Int
        var state: CodexRolloutState
        switch mode {
        case .fromStart:
            startOffset = 0
            firstSeq = 0
            state = CodexRolloutState(lastKind: kind)
        case let .fromOffset(offset, nextSeq):
            startOffset = max(0, offset)
            firstSeq = max(0, nextSeq)
            state = CodexRolloutState.decode(cursor?.adapterState) ?? CodexRolloutState(lastKind: kind)
        }
        state.lastKind = kind
        state.path = unit.path

        var batch = AgentHistoryIngestBatch(cursor: base, hasMore: false)
        guard let nativeID = unit.nativeSessionID.flatMap(AgentHistoryAgent.codex.normalizedSessionID) else {
            let rawID = unit.nativeSessionID ?? unit.key
            batch.diagnostics.skippedSessions[rawID] = .invalidSessionID
            state.reachedEOF = true
            batch.cursor = base.advanced(identity: identity, byteOffset: startOffset, nextSeq: firstSeq,
                                         fingerprint: base.fingerprint, adapterState: state.encoded())
            return batch
        }

        let lookup = catalog.lookup()
        batch.problem = lookup.problem
        let row = lookup.snapshot?.rows[nativeID]
        if row?.isChild == true {
            state.isChild = true
        }

        var processor = CodexRolloutLineProcessor(
            nativeID: nativeID,
            hasCatalogRow: row != nil,
            catalogCwd: row?.cwd.map { AgentHistoryPath.canonical($0) },
            context: context,
            state: state,
            builder: AgentHistoryBatchBuilder(session: AgentHistorySessionDraft(nativeID: nativeID), firstSeq: firstSeq, context: context)
        )
        if let row {
            Self.applyCatalogRow(row, to: &processor.builder, context: context)
        }

        func finish(byteOffset: Int64, fingerprint: Int64?) -> AgentHistoryIngestBatch {
            var finished = batch
            finished.diagnostics.malformedLines += processor.diagnostics.malformedLines
            finished.diagnostics.oversizedLines += processor.diagnostics.oversizedLines
            finished.diagnostics.skippedRecords += processor.diagnostics.skippedRecords
            finished.cursor = base.advanced(
                identity: identity, byteOffset: byteOffset, nextSeq: processor.builder.nextSeq,
                fingerprint: fingerprint, adapterState: processor.state.encoded()
            )
            return finished
        }

        // Tombstones (and exclusions, when the folder is already known) reject before any read.
        if !processor.state.isChild, let decision = processor.decideEarly(), decision != .admit {
            if kind == .zst {
                dropZstdContinuation(key: unit.key)
            }
            return Self.rejected(finish(byteOffset: startOffset, fingerprint: base.fingerprint), nativeID: nativeID, decision: decision)
        }

        var outcome = CodexRolloutLineProcessor.Outcome.continue
        let committed: Int64
        let reachedEOF: Bool
        let fingerprint: Int64?
        if kind == .zst, startOffset > 0, base.fingerprint != nil,
           ZstdByteSource.frameContentSize(path: unit.path) == startOffset {
            // Nothing past the cursor (a rollout that was moved, or compressed after it was read
            // in full): refresh the session's metadata without decompressing the file.
            dropZstdContinuation(key: unit.key)
            committed = startOffset
            reachedEOF = true
            fingerprint = base.fingerprint
        } else {
            // Open (or resume) the stream.
            var reader: JSONLTailReader
            var window: CodexWindowRecordingSource?
            if kind == .zst {
                if let continuation = takeZstdContinuation(key: unit.key, identity: identity, offset: startOffset) {
                    reader = continuation.reader
                    window = continuation.window
                } else {
                    noteZstdStreamOpened()
                    let recorder = CodexWindowRecordingSource(
                        base: try ZstdByteSource(path: unit.path), startOffset: 0, capacity: Self.windowCapacity
                    )
                    try recorder.discard(startOffset)
                    reader = JSONLTailReader(source: recorder, startOffset: startOffset, chunkSize: Self.readerChunkSize,
                                             isCancelled: context.isCancelled)
                    window = recorder
                }
            } else {
                reader = JSONLTailReader(source: try FileByteSource(path: unit.path, offset: startOffset), startOffset: startOffset,
                                         chunkSize: Self.readerChunkSize, isCancelled: context.isCancelled)
            }

            let byteLimit = Int64(context.limits.sourceBytes)
            let stats = try reader.readLines { line, endOffset in
                if processor.state.isChild {
                    return .continue
                }
                outcome = processor.process(line)
                if outcome != .continue {
                    return outcome == .child ? .continue : .stop
                }
                if processor.builder.isFull || endOffset - startOffset >= byteLimit {
                    return .stop
                }
                return .continue
            }
            processor.diagnostics.oversizedLines += stats.oversizedLines
            committed = stats.committedOffset
            reachedEOF = stats.reachedEOF
            if let window {
                fingerprint = window.fingerprint(endOffset: committed) ?? ZstdByteSource.fingerprint(path: unit.path, endOffset: committed)
            } else {
                fingerprint = AgentHistoryFileFingerprint.compute(path: unit.path, endOffset: committed)
            }
            // Plain rollouts never touch the parked streams; `takeZstdContinuation` already removed
            // this unit's stream, so a finished or rejected compressed rollout leaves nothing behind.
            if let window, !reachedEOF, outcome == .continue || outcome == .child {
                storeZstdContinuation(CodexZstdContinuation(key: unit.key, identity: identity, offset: committed, reader: reader, window: window))
            }
        }
        processor.state.reachedEOF = reachedEOF

        if outcome == .rejected, let decision = processor.decision {
            processor.state.reachedEOF = true
            return Self.rejected(finish(byteOffset: startOffset, fingerprint: base.fingerprint), nativeID: nativeID, decision: decision)
        }

        var result = finish(byteOffset: committed, fingerprint: fingerprint)
        result.hasMore = !reachedEOF
        if processor.state.isChild {
            result.removedNativeIDs = [nativeID]
            result.diagnostics.skippedSessions[nativeID] = .child
            return result
        }

        var session = processor.builder.session
        if row?.cwd == nil, let cwd = processor.state.cwd {
            Self.applyFolder(cwd, to: &session, context: context)
        }
        session.branch = row?.branch ?? processor.state.branch ?? session.branch
        session.model = row?.model ?? processor.state.model ?? session.model
        session.effort = row?.effort ?? processor.state.effort ?? session.effort
        session.archived = (row?.archived ?? false) || Self.isArchivedPath(unit.path, root: root.path)
        if let started = processor.state.startedAtMs {
            session.createdAtMs = session.createdAtMs.map { min($0, started) } ?? started
        }
        session.transcriptPath = unit.path
        result.sessions = [session]
        let (messages, artifacts) = processor.builder.drafts()
        result.messages = messages
        result.artifacts = artifacts
        return result
    }

    private static func rejected(
        _ batch: AgentHistoryIngestBatch,
        nativeID: String,
        decision: AgentHistoryAdmissionDecision
    ) -> AgentHistoryIngestBatch {
        var rejected = batch
        rejected.rejected[nativeID] = decision
        rejected.removedNativeIDs = [nativeID]
        rejected.diagnostics.skippedSessions[nativeID] = decision == .tombstoned ? .tombstoned : .excluded
        rejected.hasMore = false
        return rejected
    }

    static func isArchivedPath(_ path: String, root: String) -> Bool {
        path.hasPrefix((root as NSString).appendingPathComponent(archivedDirectory) + "/")
    }
}
