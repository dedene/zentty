import AppKit
import os

private enum RemoteImagePasteFailure: Equatable {
    case authRequired
    case hostUnreachable
    case transferFailed
    case unknownDestination
    case imageTooLarge
    case fileTooLarge
    case foldersCannotUpload
    case uploadAlreadyInProgress

    init(error: RemoteImageUploadError) {
        switch error {
        case .authRequired:
            self = .authRequired
        case .hostUnreachable:
            self = .hostUnreachable
        case .timeout, .transferFailed, .invalidRemotePath:
            self = .transferFailed
        }
    }

    var message: String {
        switch self {
        case .authRequired:
            return "Couldn't upload file — ssh key auth required"
        case .hostUnreachable:
            return "Couldn't upload file — host unreachable"
        case .transferFailed:
            return "Couldn't upload file — transfer failed"
        case .unknownDestination:
            return "Couldn't upload file — unknown ssh destination"
        case .imageTooLarge:
            return "Image too large to upload (max 10 MB)"
        case .fileTooLarge:
            return "File too large to upload (max 500 MB)"
        case .foldersCannotUpload:
            return "Folders can't be uploaded"
        case .uploadAlreadyInProgress:
            return "Upload already in progress"
        }
    }

    var displayDuration: TimeInterval {
        2.5
    }
}

private extension TerminalClipboard.ImageUploadContent {
    var remoteImagePasteboardContents: RemoteImagePasteboardContents {
        switch self {
        case .image:
            return .imageData
        case .imageTooLarge, .failedToReadImage:
            return .imageTooLarge
        case .noImage:
            return .empty
        }
    }
}

private final class LockedSSHScanResult: @unchecked Sendable {
    private let lock = NSLock()
    private var destination: SSHDestination?

    func set(_ destination: SSHDestination?) {
        lock.lock()
        self.destination = destination
        lock.unlock()
    }

    func get() -> SSHDestination? {
        lock.lock()
        defer { lock.unlock() }
        return destination
    }
}

/// Owns remote (ssh) clipboard image/file pasting: it detects when the focused
/// pane targets a remote host, uploads pasted images/files over scp, and drives
/// the progress toast. It also runs the foreground-ssh probe loop that keeps the
/// per-pane remote destination fresh.
@MainActor
final class RemoteImagePasteController {
    private struct ForegroundSSHProbeSource: Sendable {
        let paneID: PaneID
        let rootPID: Int32?
    }

    private struct ForegroundSSHProbeResult: Sendable {
        let paneID: PaneID
        let destination: SSHDestination?
    }

    private static let remoteImagePasteLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "be.zenjoy.zentty",
        category: "RemoteImagePaste"
    )
    private static let foregroundSSHProbeIntervalNanoseconds: UInt64 = 2_000_000_000
    private static let foregroundSSHOnDemandTimeout: TimeInterval = 1

    private let worklaneStore: WorklaneStore
    private let runtimeRegistry: PaneRuntimeRegistry
    private let remoteImageUploader: RemoteImageUploader
    private let sshProcessProbe: PaneSSHProcessProbe
    private let toasts: WindowToastPresenter
    private var remoteImageUploadTasksByPaneID: [PaneID: Task<Void, Never>] = [:]
    private var foregroundSSHProbeTask: Task<Void, Never>?

    init(
        worklaneStore: WorklaneStore,
        runtimeRegistry: PaneRuntimeRegistry,
        uploader: RemoteImageUploader,
        sshProcessProbe: PaneSSHProcessProbe,
        toasts: WindowToastPresenter
    ) {
        self.worklaneStore = worklaneStore
        self.runtimeRegistry = runtimeRegistry
        self.remoteImageUploader = uploader
        self.sshProcessProbe = sshProcessProbe
        self.toasts = toasts
    }

    deinit {
        MainActorShim.assumeIsolated {
            for task in remoteImageUploadTasksByPaneID.values {
                task.cancel()
            }
            foregroundSSHProbeTask?.cancel()
        }
    }

    func configure(runtime: PaneRuntime) {
        let paneID = runtime.paneID
        runtime.setRemoteImagePasteHandler { [weak self] pasteboard, _ in
            self?.handlePaste(paneID: paneID, pasteboard: pasteboard) ?? false
        }
    }

    func handlePaste(paneID: PaneID, pasteboard: NSPasteboard) -> Bool {
        let fileURLs = TerminalClipboard.fileURLs(from: pasteboard)
        let imageContent: TerminalClipboard.ImageUploadContent = fileURLs.isEmpty
            ? TerminalClipboard.imageUploadContent(from: pasteboard)
            : .noImage
        let pasteboardContents: RemoteImagePasteboardContents = fileURLs.isEmpty
            ? imageContent.remoteImagePasteboardContents
            : .fileURL

        guard pasteboardContents.shouldUpload else {
            return false
        }

        guard let paneState = remoteImagePastePaneState(for: paneID, refreshForegroundSSH: true) else {
            return false
        }

        guard RemoteImagePasteDecision.shouldUploadRemotely(
            paneState: paneState,
            pasteboardContents: pasteboardContents
        ) else {
            return false
        }

        guard remoteImageUploadTasksByPaneID[paneID] == nil else {
            showRemoteImagePasteFailure(.uploadAlreadyInProgress, paneID: paneID)
            return true
        }

        guard let destination = paneState.destination else {
            showRemoteImagePasteFailure(.unknownDestination, paneID: paneID)
            return true
        }

        if !fileURLs.isEmpty {
            return handleRemoteFileURLPaste(
                paneID: paneID,
                fileURLs: fileURLs,
                destination: destination
            )
        }

        let pastedImage: TerminalClipboard.PastedImage
        switch imageContent {
        case .image(let image):
            pastedImage = image
        case .imageTooLarge:
            showRemoteImagePasteFailure(.imageTooLarge, paneID: paneID)
            return true
        case .failedToReadImage:
            showRemoteImagePasteFailure(.transferFailed, paneID: paneID)
            return true
        case .noImage:
            return false
        }

        let toastHandle = beginRemoteImageUploadToast(
            message: Self.remoteImageUploadProgressMessage(fraction: 0)
        )
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                remoteImageUploadTasksByPaneID[paneID] = nil
            }

            do {
                let remotePath = try await remoteImageUploader.upload(
                    imageData: pastedImage.data,
                    fileExtension: pastedImage.fileExtension,
                    destination: destination,
                    progress: { fraction in
                        toastHandle.updateProgress(
                            fraction: fraction,
                            message: Self.remoteImageUploadProgressMessage(fraction: fraction)
                        )
                    }
                )

                guard !Task.isCancelled else {
                    return
                }

                toastHandle.finish(message: "Pasted remote path", icon: "checkmark.circle.fill")
                runtimeRegistry.runtime(for: paneID)?.adapter.sendText(ShellEscaping.escapePath(remotePath))
            } catch let error as RemoteImageUploadError {
                let failure = RemoteImagePasteFailure(error: error)
                Self.remoteImagePasteLogger.error("Remote image upload failed for pane \(paneID.rawValue): \(String(describing: error))")
                toastHandle.fail(message: failure.message)
            } catch is CancellationError {
                Self.remoteImagePasteLogger.debug("Remote image upload cancelled for pane \(paneID.rawValue)")
            } catch {
                Self.remoteImagePasteLogger.error("Remote image upload failed for pane \(paneID.rawValue): \(error.localizedDescription)")
                toastHandle.fail(message: RemoteImagePasteFailure.transferFailed.message)
            }

        }
        remoteImageUploadTasksByPaneID[paneID] = task
        return true
    }

    private func handleRemoteFileURLPaste(
        paneID: PaneID,
        fileURLs: [URL],
        destination: SSHDestination
    ) -> Bool {
        let resolution = RemoteFileUploadRequestResolver.resolve(fileURLs: fileURLs)
        let uploadRequests: [RemoteFileUploadRequest]
        switch resolution {
        case .files(let requests):
            uploadRequests = requests
        case .noFiles:
            return false
        case .foldersOnly:
            showRemoteImagePasteFailure(.foldersCannotUpload, paneID: paneID)
            return true
        case .fileTooLarge:
            showRemoteImagePasteFailure(.fileTooLarge, paneID: paneID)
            return true
        case .failedToResolve:
            showRemoteImagePasteFailure(.transferFailed, paneID: paneID)
            return true
        }

        guard let firstRequest = uploadRequests.first else {
            return false
        }

        let toastHandle = beginRemoteImageUploadToast(
            message: Self.remoteFileUploadProgressMessage(
                filename: firstRequest.originalFilename,
                fileIndex: 1,
                fileCount: uploadRequests.count,
                fraction: 0
            )
        )
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                remoteImageUploadTasksByPaneID[paneID] = nil
            }

            do {
                let batch = RemoteFileUploadBatch(uploader: remoteImageUploader)
                let result = try await batch.uploadFiles(
                    uploadRequests,
                    destination: destination,
                    progress: { progress in
                        toastHandle.updateProgress(
                            fraction: progress.fraction,
                            message: Self.remoteFileUploadProgressMessage(progress)
                        )
                    }
                )

                guard !Task.isCancelled else {
                    return
                }

                guard !result.successfulRemotePaths.isEmpty else {
                    let failure = result.firstFailure.map(RemoteImagePasteFailure.init(error:)) ?? .transferFailed
                    toastHandle.fail(message: failure.message)
                    return
                }

                if result.failedCount > 0 {
                    toastHandle.finish(
                        message: "Uploaded \(result.successfulRemotePaths.count) of \(result.totalCount) files",
                        icon: "checkmark.circle.fill"
                    )
                } else {
                    toastHandle.finish(
                        message: result.totalCount == 1 ? "Pasted remote path" : "Pasted remote paths",
                        icon: "checkmark.circle.fill"
                    )
                }
                runtimeRegistry.runtime(for: paneID)?.adapter.sendText(result.pasteText)
            } catch is CancellationError {
                Self.remoteImagePasteLogger.debug("Remote file upload cancelled for pane \(paneID.rawValue)")
            } catch {
                Self.remoteImagePasteLogger.error("Remote file upload failed for pane \(paneID.rawValue): \(error.localizedDescription)")
                toastHandle.fail(message: RemoteImagePasteFailure.transferFailed.message)
            }
        }
        remoteImageUploadTasksByPaneID[paneID] = task
        return true
    }

    private func remoteImagePastePaneState(
        for paneID: PaneID,
        refreshForegroundSSH: Bool = false
    ) -> RemoteImagePastePaneState? {
        guard let worklane = worklaneStore.worklanes.first(where: { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == paneID })
        }),
            var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID]
        else {
            return nil
        }

        if refreshForegroundSSH {
            let destination = auxiliaryState.raw.paneRootPID
                .flatMap { scanForegroundSSHDestinationForPaste(rootPID: $0) }
            if auxiliaryState.raw.foregroundSSHDestination != destination {
                worklaneStore.updateForegroundSSHDestination(
                    paneID: paneID,
                    destination: destination
                )
            }
            auxiliaryState.raw.foregroundSSHDestination = destination
            auxiliaryState.presentation.foregroundSSHDestination = destination
        }

        let presentation = auxiliaryState.presentation
        return RemoteImagePastePaneState(
            isRemotePane: presentation.isRemotePane,
            destination: remoteImageDestination(from: auxiliaryState)
        )
    }

    private func remoteImageDestination(from auxiliaryState: PaneAuxiliaryState) -> SSHDestination? {
        RemoteImagePasteDestination.destination(from: auxiliaryState)
    }

    func cancelAll() {
        let tasks = Array(remoteImageUploadTasksByPaneID.values)
        remoteImageUploadTasksByPaneID.removeAll()
        tasks.forEach { $0.cancel() }
        toasts.dismiss()
    }

    func cancelUploadsForRemovedPanes() {
        let livePaneIDs = Set(worklaneStore.worklanes.flatMap { worklane in
            worklane.paneStripState.panes.map(\.id)
        })
        for paneID in Array(remoteImageUploadTasksByPaneID.keys) where !livePaneIDs.contains(paneID) {
            cancelRemoteImageUpload(for: paneID)
        }
    }

    private func cancelRemoteImageUpload(for paneID: PaneID) {
        guard let task = remoteImageUploadTasksByPaneID.removeValue(forKey: paneID) else {
            return
        }

        task.cancel()
        if remoteImageUploadTasksByPaneID.isEmpty {
            toasts.dismiss()
        }
    }

    private func beginRemoteImageUploadToast(message: String) -> PathCopiedToastView.ProgressHandle {
        toasts.beginProgress(message: message)
    }

    private func showRemoteImagePasteFailure(_ failure: RemoteImagePasteFailure, paneID: PaneID) {
        Self.remoteImagePasteLogger.error("Remote image paste failed for pane \(paneID.rawValue): \(failure.message)")
        if failure == .uploadAlreadyInProgress, toasts.isProgressActive {
            toasts.temporarilyShowProgressMessage(failure.message, duration: failure.displayDuration)
            return
        }

        toasts.show(message: failure.message, duration: failure.displayDuration)
    }

    private static func remoteImageUploadProgressMessage(fraction: Double) -> String {
        let percent = Int((max(0, min(1, fraction)) * 100).rounded())
        return "Uploading pasted image (\(percent)%)"
    }

    private static func remoteFileUploadProgressMessage(_ progress: RemoteFileUploadProgress) -> String {
        remoteFileUploadProgressMessage(
            filename: progress.filename,
            fileIndex: progress.fileIndex,
            fileCount: progress.fileCount,
            fraction: progress.fraction
        )
    }

    private static func remoteFileUploadProgressMessage(
        filename: String,
        fileIndex: Int,
        fileCount: Int,
        fraction: Double
    ) -> String {
        let percent = Int((max(0, min(1, fraction)) * 100).rounded())
        if fileCount > 1 {
            return "Uploading \(filename) (\(fileIndex)/\(fileCount), \(percent)%)"
        }

        return "Uploading \(filename) (\(percent)%)"
    }

    func startForegroundSSHProbeLoop() {
        foregroundSSHProbeTask?.cancel()
        foregroundSSHProbeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleForegroundSSHProcesses()
                try? await Task.sleep(nanoseconds: Self.foregroundSSHProbeIntervalNanoseconds)
            }
        }
    }

    func stopForegroundSSHProbe() {
        foregroundSSHProbeTask?.cancel()
        foregroundSSHProbeTask = nil
    }

    private func sampleForegroundSSHProcesses() async {
        let sources = foregroundSSHProbeSources()
        guard !sources.isEmpty else {
            return
        }

        let probe = sshProcessProbe
        let results = await Task.detached(priority: .utility) {
            sources.map { source in
                ForegroundSSHProbeResult(
                    paneID: source.paneID,
                    destination: source.rootPID.flatMap { probe.scan(rootPID: $0) }
                )
            }
        }.value

        guard !Task.isCancelled else {
            return
        }

        for result in results {
            worklaneStore.updateForegroundSSHDestination(
                paneID: result.paneID,
                destination: result.destination
            )
        }
    }

    private func foregroundSSHProbeSources() -> [ForegroundSSHProbeSource] {
        worklaneStore.worklanes.flatMap { worklane in
            worklane.paneStripState.panes.map { pane in
                ForegroundSSHProbeSource(
                    paneID: pane.id,
                    rootPID: worklane.auxiliaryStateByPaneID[pane.id]?.raw.paneRootPID
                )
            }
        }
    }

    private func scanForegroundSSHDestinationForPaste(rootPID: Int32) -> SSHDestination? {
        let probe = sshProcessProbe
        let result = LockedSSHScanResult()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            result.set(probe.scan(rootPID: rootPID))
            semaphore.signal()
        }

        let timeout = DispatchTime.now() + Self.foregroundSSHOnDemandTimeout
        guard semaphore.wait(timeout: timeout) == .success else {
            Self.remoteImagePasteLogger.error("Timed out scanning foreground ssh process for rootPID \(rootPID, privacy: .public)")
            return nil
        }

        return result.get()
    }

#if DEBUG
    func insertUploadTaskForTesting(
        _ task: Task<Void, Never>,
        for paneID: PaneID
    ) {
        remoteImageUploadTasksByPaneID[paneID] = task
    }

    func hasUploadTaskForTesting(for paneID: PaneID) -> Bool {
        remoteImageUploadTasksByPaneID[paneID] != nil
    }
#endif
}
