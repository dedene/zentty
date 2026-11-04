import Darwin
import Foundation

/// Indexes Claude Code transcripts under one Claude root (`~/.claude`, `$CLAUDE_CONFIG_DIR`, …).
///
/// - Units: `projects/<encoded cwd>/<session uuid>.jsonl`, one session each. The unit key is the
///   normalized session id. Nested folders (`<uuid>/subagents/`, `tool-results/`, `workflows/`)
///   are never units: subagent transcripts are not sessions (D13).
/// - The session's cwd is decided before any message text is decoded: the first record `cwd`
///   whose Claude folder encoding (`[^A-Za-z0-9]` → `-`) equals the project folder name, else
///   the first `cwd` seen. It is kept in `cursor.adapterState` so appends can run admission.
/// - Headless (`entrypoint == "sdk-cli"`) sessions are indexed like any other (D12).
///
/// Immutable after `init`; ingest runs on the indexer queue only.
final class ClaudeHistorySource: AgentHistorySource {
    static let currentAdapterVersion = 1

    let root: AgentHistorySourceRoot
    let adapterVersion = ClaudeHistorySource.currentAdapterVersion
    var agent: AgentHistoryAgent { .claude }
    var watchPaths: [String] { [projectsPath] }

    /// `<root>/projects`, canonical.
    private let projectsPath: String
    /// Spellings of `projectsPath` an FSEvents path may use (canonical and realpath).
    private let projectsPathSpellings: Set<String>

    init(root: AgentHistorySourceRoot) {
        self.root = root
        let projects = AgentHistoryPath.canonical(root.path + "/projects")
        self.projectsPath = projects
        var spellings: Set<String> = [projects]
        if let real = Self.realpathString(projects) {
            spellings.insert(real)
        } else if let realRoot = Self.realpathString(root.path) {
            spellings.insert(realRoot + "/projects")
        }
        self.projectsPathSpellings = spellings
    }

    // MARK: - Discovery

    func discoverUnits() throws -> [AgentHistoryUnit] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw POSIXError(.ENOENT)
        }
        guard fileManager.fileExists(atPath: projectsPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        var units: [String: AgentHistoryUnit] = [:]
        for project in try fileManager.contentsOfDirectory(atPath: projectsPath) where !project.hasPrefix(".") {
            let projectPath = projectsPath + "/" + project
            // Plain files and unreadable folders are not projects.
            guard let names = try? fileManager.contentsOfDirectory(atPath: projectPath) else {
                continue
            }
            for name in names {
                guard let sessionID = Self.sessionID(fileName: name) else {
                    continue
                }
                let path = projectPath + "/" + name
                guard let identity = Self.regularFileIdentity(path) else {
                    continue
                }
                // The same id in two project folders: keep the most recently written file.
                if let existing = units[sessionID], let existingIdentity = existing.identity,
                   existingIdentity.mtimeNs >= identity.mtimeNs {
                    continue
                }
                units[sessionID] = AgentHistoryUnit(
                    key: sessionID, path: path, kind: .jsonl, identity: identity, nativeSessionID: sessionID
                )
            }
        }
        return units.values.sorted { lhs, rhs in
            let left = lhs.identity?.mtimeNs ?? 0
            let right = rhs.identity?.mtimeNs ?? 0
            return left != right ? left > right : lhs.key < rhs.key
        }
    }

    func eventTarget(forCanonicalPath path: String) -> AgentHistoryEventTarget? {
        let fileName = (path as NSString).lastPathComponent
        guard let sessionID = Self.sessionID(fileName: fileName) else {
            return nil
        }
        let projectPath = (path as NSString).deletingLastPathComponent
        let project = (projectPath as NSString).lastPathComponent
        guard !project.isEmpty, !project.hasPrefix("."), project != "/" else {
            return nil
        }
        guard projectsPathSpellings.contains((projectPath as NSString).deletingLastPathComponent) else {
            return nil
        }
        return .unit(sessionID)
    }

    func estimatedSessionCount() -> Int? {
        try? discoverUnits().count
    }

    // MARK: - Ingest

    func ingest(
        unit: AgentHistoryUnit,
        cursor: AgentHistoryCursor?,
        mode: AgentHistoryIngestMode,
        context: AgentHistoryIngestContext
    ) throws -> AgentHistoryIngestBatch {
        let base = cursor ?? AgentHistoryCursor(sourceID: 0, unitKey: unit.key)
        var batch = AgentHistoryIngestBatch(cursor: base, hasMore: false)

        guard let rawID = unit.nativeSessionID, let nativeID = agent.normalizedSessionID(rawID) else {
            batch.diagnostics.skippedSessions[unit.nativeSessionID ?? unit.key] = .invalidSessionID
            return batch
        }

        let startOffset: Int64
        let firstSeq: Int
        var state: ClaudeHistoryAdapterState
        switch mode {
        case .fromStart:
            startOffset = 0
            firstSeq = 0
            state = ClaudeHistoryAdapterState()
        case let .fromOffset(offset, nextSeq):
            startOffset = max(offset, 0)
            firstSeq = max(nextSeq, 0)
            state = ClaudeHistoryAdapterState.decoded(from: cursor?.adapterState)
        }

        // A-5: the identity is the stat taken before reading.
        guard let identity = AgentHistoryFileIdentity.stat(path: unit.path) else {
            throw POSIXError(.ENOENT)
        }

        if state.cwd == nil {
            state.cwd = try Self.sessionCwd(
                path: unit.path,
                startOffset: startOffset,
                projectName: ((unit.path as NSString).deletingLastPathComponent as NSString).lastPathComponent,
                byteLimit: Int64(context.limits.sourceBytes),
                isCancelled: context.isCancelled
            )
        }
        let canonicalCwd = state.cwd.map { AgentHistoryPath.canonical($0) }

        let decision = context.admission.decide(agent: agent, nativeID: nativeID, cwd: canonicalCwd)
        guard decision == .admit else {
            batch.rejected[nativeID] = decision
            batch.removedNativeIDs = [nativeID]
            batch.diagnostics.skippedSessions[nativeID] = decision == .tombstoned ? .tombstoned : .excluded
            batch.cursor = base.advanced(
                identity: identity,
                byteOffset: startOffset,
                nextSeq: firstSeq,
                fingerprint: AgentHistoryFileFingerprint.compute(path: unit.path, endOffset: startOffset),
                adapterState: state.encoded()
            )
            return batch
        }

        var session = AgentHistorySessionDraft(nativeID: nativeID)
        session.transcriptPath = unit.path
        var pathBases: [String] = []
        if let canonicalCwd, let rawCwd = state.cwd {
            session.cwd = canonicalCwd
            if let repository = context.repositories.identity(for: canonicalCwd) {
                session.repoRoot = repository.repoRoot
                session.mainRepoRoot = repository.mainRepoRoot
                pathBases.append(repository.repoRoot)
            }
            pathBases.append(rawCwd)
            if canonicalCwd != rawCwd {
                pathBases.append(canonicalCwd)
            }
        }

        var parser = ClaudeTranscriptParser(
            builder: AgentHistoryBatchBuilder(session: session, firstSeq: firstSeq, context: context),
            state: state,
            pathBases: pathBases,
            fallbackAtMs: identity.mtimeNs / 1_000_000
        )

        let byteLimit = Int64(context.limits.sourceBytes)
        var hitLimit = false
        var reader = JSONLTailReader(
            source: try FileByteSource(path: unit.path, offset: startOffset),
            startOffset: startOffset,
            isCancelled: context.isCancelled
        )
        let stats = try reader.readLines { line, endOffset in
            parser.consume(line)
            if parser.builder.isFull || endOffset - startOffset >= byteLimit {
                hitLimit = true
                return .stop
            }
            return .continue
        }
        if stats.cancelled {
            throw CancellationError()
        }

        batch.sessions = [parser.builder.session]
        (batch.messages, batch.artifacts) = parser.builder.drafts()
        if startOffset == 0 {
            batch.replaceContentOf = [nativeID]
        }
        batch.diagnostics = parser.diagnostics
        batch.diagnostics.oversizedLines += stats.oversizedLines
        batch.hasMore = hitLimit && stats.committedOffset < identity.size
        batch.cursor = base.advanced(
            identity: identity,
            byteOffset: stats.committedOffset,
            nextSeq: parser.builder.nextSeq,
            fingerprint: AgentHistoryFileFingerprint.compute(path: unit.path, endOffset: stats.committedOffset),
            adapterState: parser.state.encoded()
        )
        AgentHistoryLog.indexer.debug(
            "Claude batch: \(batch.messages.count, privacy: .public) messages, \(batch.artifacts.count, privacy: .public) artifacts, \(batch.diagnostics.malformedLines, privacy: .public) malformed"
        )
        return batch
    }

    // MARK: - Helpers

    /// The normalized session id of `<uuid>.jsonl`, else nil.
    static func sessionID(fileName: String) -> String? {
        guard fileName.hasSuffix(".jsonl"), !fileName.hasPrefix(".") else {
            return nil
        }
        return AgentHistoryAgent.claude.normalizedSessionID(String(fileName.dropLast(".jsonl".count)))
    }

    /// Claude's project folder name for a cwd: every UTF-16 unit outside `[A-Za-z0-9]` becomes `-`.
    static func projectDirectoryName(forCwd cwd: String) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(cwd.utf16.count)
        for unit in cwd.utf16 {
            let isAlphanumeric = (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
            units.append(isAlphanumeric ? unit : 0x2D)
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Scans from `startOffset` (at most `byteLimit` bytes) for the session cwd without decoding
    /// any message: the first `cwd` that encodes to `projectName`, else the first `cwd` seen.
    private static func sessionCwd(
        path: String,
        startOffset: Int64,
        projectName: String,
        byteLimit: Int64,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> String? {
        var first: String?
        var match: String?
        var reader = JSONLTailReader(
            source: try FileByteSource(path: path, offset: startOffset),
            startOffset: startOffset,
            isCancelled: isCancelled
        )
        let stats = try reader.readLines { line, endOffset in
            if JSONLineSniffer.contains("\"cwd\"", in: line),
               let top = JSONLineSniffer.topLevel(in: line, stringKeys: ["cwd"], flagKeys: [], presenceKeys: []),
               let cwd = top.strings["cwd"], cwd.hasPrefix("/") {
                if projectDirectoryName(forCwd: cwd) == projectName {
                    match = cwd
                    return .stop
                }
                if first == nil {
                    first = cwd
                }
            }
            return endOffset - startOffset >= byteLimit ? .stop : .continue
        }
        if stats.cancelled {
            throw CancellationError()
        }
        return match ?? first
    }

    /// stat(2) identity of a regular file (symlinks followed); nil for anything else.
    private static func regularFileIdentity(_ path: String) -> AgentHistoryFileIdentity? {
        var info = Darwin.stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        let mtime = info.st_mtimespec
        return AgentHistoryFileIdentity(
            dev: Int64(info.st_dev),
            ino: Int64(bitPattern: UInt64(info.st_ino)),
            size: Int64(info.st_size),
            mtimeNs: Int64(mtime.tv_sec) &* 1_000_000_000 &+ Int64(mtime.tv_nsec)
        )
    }

    private static func realpathString(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else {
            return nil
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
