import Foundation

/// Collects one session's messages, artifacts and titles for a batch, applying the shared
/// text pipeline so every adapter stores the same shape:
/// raw → `redactor.redact` → `AgentHistoryDisplayText.displayText` → `AgentHistorySearchText.normalize`.
///
/// Messages get consecutive `seq` values from `firstSeq`. Artifacts carry the `seq` of the
/// latest message added before them (`firstSeq - 1`, floored at 0, when none was) and are
/// deduped by `(kind, value)`. Message times also widen the session's `createdAtMs` /
/// `updatedAtMs` and, for user turns, `lastUserAtMs`.
struct AgentHistoryBatchBuilder {
    var session: AgentHistorySessionDraft

    private let context: AgentHistoryIngestContext
    private(set) var nextSeq: Int
    private var messages: [AgentHistoryMessageDraft] = []
    private var artifacts: [AgentHistoryArtifactDraft] = []
    private var artifactKeys = Set<ArtifactKey>()
    private var notedFirstPrompt = false

    private struct ArtifactKey: Hashable {
        let kind: AgentHistoryArtifactKind
        let value: String
    }

    init(session: AgentHistorySessionDraft, firstSeq: Int, context: AgentHistoryIngestContext) {
        self.session = session
        self.nextSeq = max(firstSeq, 0)
        self.context = context
    }

    /// True once the batch holds `context.limits.messages` messages. Adapters stop at the next
    /// record boundary; the byte cap (`limits.sourceBytes`) is theirs to track.
    var isFull: Bool {
        messages.count >= context.limits.messages
    }

    var messageCount: Int { messages.count }

    /// Adds a message; false (and no `seq` used) when nothing displayable remains.
    @discardableResult
    mutating func addMessage(role: AgentHistoryRole, atMs: Int64, rawText: String) -> Bool {
        let redacted = context.redactor.redact(rawText)
        guard let text = AgentHistoryDisplayText.displayText(redacted) else {
            return false
        }
        messages.append(AgentHistoryMessageDraft(
            sessionNativeID: session.nativeID,
            seq: nextSeq,
            role: role,
            atMs: atMs,
            text: text,
            searchText: AgentHistorySearchText.normalize(text)
        ))
        nextSeq += 1
        session.createdAtMs = session.createdAtMs.map { min($0, atMs) } ?? atMs
        session.updatedAtMs = session.updatedAtMs.map { max($0, atMs) } ?? atMs
        if role == .user {
            session.lastUserAtMs = session.lastUserAtMs.map { max($0, atMs) } ?? atMs
        }
        return true
    }

    mutating func addArtifact(_ kind: AgentHistoryArtifactKind, rawValue: String, atMs: Int64) {
        let redacted = context.redactor.redact(rawValue)
        let value = redacted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, artifactKeys.insert(ArtifactKey(kind: kind, value: value)).inserted else {
            return
        }
        artifacts.append(AgentHistoryArtifactDraft(
            sessionNativeID: session.nativeID,
            seq: max(nextSeq - 1, 0),
            kind: kind,
            value: value,
            searchText: AgentHistorySearchText.normalize(value),
            atMs: atMs
        ))
    }

    /// Offers a title; redacted (A-9) and merged with the shared title precedence.
    mutating func noteTitle(_ raw: String?, kind: AgentHistoryTitleKind) {
        guard let raw else {
            return
        }
        let redacted = context.redactor.redact(raw)
        guard let display = AgentHistoryDisplayText.displayText(redacted) else {
            return
        }
        let title = AgentHistoryDisplayText.firstPromptTitle(display, limit: AgentHistoryDisplayText.maxStoredCharacters)
        var update = AgentHistorySessionDraft(nativeID: session.nativeID)
        update.title = title
        update.titleKind = kind
        session = AgentHistorySessionDraft.merged(existing: session, update: update)
    }

    /// The first user prompt as a `first_prompt` title. Only the first call per builder counts.
    mutating func noteFirstPrompt(_ displayText: String) {
        guard !notedFirstPrompt else {
            return
        }
        let title = AgentHistoryDisplayText.firstPromptTitle(context.redactor.redact(displayText))
        guard !title.isEmpty else {
            return
        }
        notedFirstPrompt = true
        noteTitle(title, kind: .firstPrompt)
    }

    func drafts() -> ([AgentHistoryMessageDraft], [AgentHistoryArtifactDraft]) {
        (messages, artifacts)
    }
}

extension AgentHistoryCursor {
    /// The cursor an adapter returns after reading (A-5): identity stat'ed before reading,
    /// offset and seq after the last delivered record, fingerprint over the bytes before
    /// `byteOffset`. Clears `isRejected`; only the indexer sets it.
    func advanced(
        identity: AgentHistoryFileIdentity?,
        byteOffset: Int64,
        nextSeq: Int,
        fingerprint: Int64?,
        adapterState: Data?
    ) -> AgentHistoryCursor {
        var cursor = self
        cursor.identity = identity
        cursor.byteOffset = byteOffset
        cursor.nextSeq = nextSeq
        cursor.fingerprint = fingerprint
        cursor.adapterState = adapterState
        cursor.isRejected = false
        return cursor
    }
}
