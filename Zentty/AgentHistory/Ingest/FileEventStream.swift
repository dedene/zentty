import CoreServices
import Darwin
import Foundation

/// Swift view of `FSEventStreamEventFlags`.
struct FileEventFlags: OptionSet, Sendable, Hashable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    init(fsEventFlags: FSEventStreamEventFlags) {
        self.init(rawValue: UInt32(fsEventFlags))
    }

    static let mustScanSubDirs = FileEventFlags(constant: kFSEventStreamEventFlagMustScanSubDirs)
    static let userDropped = FileEventFlags(constant: kFSEventStreamEventFlagUserDropped)
    static let kernelDropped = FileEventFlags(constant: kFSEventStreamEventFlagKernelDropped)
    static let eventIdsWrapped = FileEventFlags(constant: kFSEventStreamEventFlagEventIdsWrapped)
    static let historyDone = FileEventFlags(constant: kFSEventStreamEventFlagHistoryDone)
    static let rootChanged = FileEventFlags(constant: kFSEventStreamEventFlagRootChanged)
    static let mount = FileEventFlags(constant: kFSEventStreamEventFlagMount)
    static let unmount = FileEventFlags(constant: kFSEventStreamEventFlagUnmount)
    static let itemCreated = FileEventFlags(constant: kFSEventStreamEventFlagItemCreated)
    static let itemRemoved = FileEventFlags(constant: kFSEventStreamEventFlagItemRemoved)
    static let itemInodeMetaMod = FileEventFlags(constant: kFSEventStreamEventFlagItemInodeMetaMod)
    static let itemRenamed = FileEventFlags(constant: kFSEventStreamEventFlagItemRenamed)
    static let itemModified = FileEventFlags(constant: kFSEventStreamEventFlagItemModified)
    static let itemIsFile = FileEventFlags(constant: kFSEventStreamEventFlagItemIsFile)
    static let itemIsDir = FileEventFlags(constant: kFSEventStreamEventFlagItemIsDir)
    static let itemIsSymlink = FileEventFlags(constant: kFSEventStreamEventFlagItemIsSymlink)

    private static let rescanMask: FileEventFlags = [
        .mustScanSubDirs, .userDropped, .kernelDropped, .rootChanged, .mount, .unmount,
    ]
    private static let droppedMask: FileEventFlags = [.userDropped, .kernelDropped]

    /// The event does not describe a single item: the watched tree must be re-scanned.
    var requiresRescan: Bool { !intersection(Self.rescanMask).isEmpty }

    /// FSEvents dropped events (user space or kernel buffer overflow).
    var isDropped: Bool { !intersection(Self.droppedMask).isEmpty }

    private init(constant: Int) {
        self.init(rawValue: UInt32(truncatingIfNeeded: constant))
    }
}

struct FileEvent: Sendable, Equatable {
    /// Real path as FSEvents reports it (symlinks resolved, `/private` kept).
    let path: String
    let flags: FileEventFlags
    let id: UInt64
}

/// File-level FSEvents stream delivering batches on a caller-supplied dispatch queue.
///
/// `start()` and `stop()` are meant to be called on `queue` (the indexer's serial queue); they are
/// also safe from other threads. Once `stop()` returns, the handler is never called again. The
/// handler must not wait synchronously on a thread that might be calling `stop()`.
final class FileEventStream: @unchecked Sendable {
    let watchedPaths: [String]

    private let latency: TimeInterval
    private let queue: DispatchQueue
    private let handler: @Sendable ([FileEvent]) -> Void
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var box: DeliveryBox?

    init(
        paths: [String],
        latency: TimeInterval = 2.0,
        queue: DispatchQueue,
        handler: @escaping @Sendable ([FileEvent]) -> Void
    ) {
        var seen = Set<String>()
        self.watchedPaths = paths
            .filter { !$0.isEmpty }
            .map(Self.canonicalPath)
            .filter { seen.insert($0).inserted }
        self.latency = latency
        self.queue = queue
        self.handler = handler
    }

    deinit {
        stop()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stream != nil
    }

    /// Starts watching from "now". Returns `true` when running (also when already running).
    @discardableResult
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stream != nil {
            return true
        }
        guard !watchedPaths.isEmpty else {
            return false
        }

        let box = DeliveryBox(handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: fileEventStreamRetainBox,
            release: fileEventStreamReleaseBox,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            fileEventStreamCallback,
            &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            AgentHistoryLog.indexer.error("FSEventStreamCreate failed for \(self.watchedPaths.count, privacy: .public) path(s)")
            return false
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            box.deactivate()
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            AgentHistoryLog.indexer.error("FSEventStreamStart failed for \(self.watchedPaths.count, privacy: .public) path(s)")
            return false
        }
        self.stream = created
        self.box = box
        return true
    }

    /// Idempotent. Stop → Invalidate → Release; no handler call happens after this returns.
    func stop() {
        lock.lock()
        let stream = self.stream
        let box = self.box
        self.stream = nil
        self.box = nil
        lock.unlock()

        box?.deactivate()
        guard let stream else {
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// realpath(3), keeping `/private` (FSEvents reports `/private/var/...`, `/private/tmp/...`).
    /// A missing path resolves its deepest existing ancestor and appends the rest. No trailing `/`
    /// except for `/` itself.
    static func canonicalPath(_ path: String) -> String {
        guard path.hasPrefix("/") else {
            return path.isEmpty ? path : strippingTrailingSlash(path)
        }
        if let resolved = realPath(path) {
            return strippingTrailingSlash(resolved)
        }
        var remainder: [String] = []
        var current = strippingTrailingSlash(path)
        while current.count > 1, current.contains("/") {
            let url = URL(fileURLWithPath: current)
            remainder.insert(url.lastPathComponent, at: 0)
            current = url.deletingLastPathComponent().path
            if let resolved = realPath(current) {
                let base = strippingTrailingSlash(resolved)
                let joined = remainder.joined(separator: "/")
                return base == "/" ? "/" + joined : base + "/" + joined
            }
        }
        return strippingTrailingSlash(path)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else {
            return nil
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func strippingTrailingSlash(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

/// Retained by the FSEvents context; gates delivery so nothing reaches the handler after `stop()`.
private final class DeliveryBox: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var isActive = true
    private let handler: @Sendable ([FileEvent]) -> Void

    init(handler: @escaping @Sendable ([FileEvent]) -> Void) {
        self.handler = handler
    }

    /// Waits for an in-flight delivery on another thread; re-entrant from inside the handler.
    func deactivate() {
        lock.lock()
        isActive = false
        lock.unlock()
    }

    func deliver(_ events: [FileEvent]) {
        lock.lock()
        defer { lock.unlock() }
        guard isActive, !events.isEmpty else {
            return
        }
        handler(events)
    }
}

private func fileEventStreamRetainBox(_ info: UnsafeRawPointer?) -> UnsafeRawPointer? {
    guard let info else {
        return nil
    }
    _ = Unmanaged<DeliveryBox>.fromOpaque(info).retain()
    return info
}

private func fileEventStreamReleaseBox(_ info: UnsafeRawPointer?) {
    guard let info else {
        return
    }
    Unmanaged<DeliveryBox>.fromOpaque(info).release()
}

private func fileEventStreamCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ eventCount: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info, eventCount > 0 else {
        return
    }
    let box = Unmanaged<DeliveryBox>.fromOpaque(info).takeUnretainedValue()
    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
    var events: [FileEvent] = []
    events.reserveCapacity(eventCount)
    for index in 0..<min(eventCount, paths.count) {
        guard let path = paths[index] as? String else {
            continue
        }
        events.append(FileEvent(
            path: path,
            flags: FileEventFlags(fsEventFlags: eventFlags[index]),
            id: UInt64(eventIds[index])
        ))
    }
    box.deliver(events)
}
