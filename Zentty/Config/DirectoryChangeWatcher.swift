import Foundation

/// Debounced change notifications for one or more directories. Watching a
/// directory rather than a file catches atomic temp+rename writes (Syncthing, editors,
/// our own saves), which replace the file's inode.
final class DirectoryChangeWatcher {
    var onChange: (@Sendable () -> Void)?

    private let queue: DispatchQueue
    private let debounceInterval: TimeInterval
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounceWorkItem: DispatchWorkItem?

    init(label: String, debounceInterval: TimeInterval = 0.15) {
        self.queue = DispatchQueue(label: label)
        self.debounceInterval = debounceInterval
    }

    func watch(directoryURL: URL) {
        watch(directoryURLs: [directoryURL])
    }

    /// Watches every distinct directory; any change in any of them fires one
    /// debounced `onChange`.
    func watch(directoryURLs: [URL]) {
        stop()

        var seenPaths = Set<String>()
        for directoryURL in directoryURLs {
            let path = directoryURL.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { continue }
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .extend, .attrib],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.scheduleChangeNotification()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        sources.forEach { $0.cancel() }
        sources = []
    }

    deinit {
        stop()
    }

    private func scheduleChangeNotification() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let onChange = self?.onChange else {
                return
            }

            onChange()
        }
        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }
}
