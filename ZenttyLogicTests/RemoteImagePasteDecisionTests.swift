import XCTest
@testable import Zentty

final class RemoteImagePasteDecisionTests: XCTestCase {
    @MainActor
    func test_cancelled_upload_does_not_clear_replacement_task() {
        let controller = makeController()
        let paneID = PaneID("pane-returned")
        let cancelledToken = controller.insertUploadTaskForTesting(Task {}, for: paneID)

        // The pane left the store, so this removes the entry and cancels the task,
        // whose defer only runs later. Then the same pane ID comes back and pastes.
        controller.cancelUploadsForRemovedPanes()
        XCTAssertFalse(controller.hasUploadTaskForTesting(for: paneID))
        let replacementToken = controller.insertUploadTaskForTesting(Task {}, for: paneID)

        controller.clearUploadTaskForTesting(for: paneID, token: cancelledToken)

        XCTAssertTrue(controller.hasUploadTaskForTesting(for: paneID, token: replacementToken))
    }

    @MainActor
    func test_completed_upload_clears_its_own_task() {
        let controller = makeController()
        let paneID = PaneID("pane-finished")
        let token = controller.insertUploadTaskForTesting(Task {}, for: paneID)

        controller.clearUploadTaskForTesting(for: paneID, token: token)

        XCTAssertFalse(controller.hasUploadTaskForTesting(for: paneID))
    }

    @MainActor
    private func makeController() -> RemoteImagePasteController {
        RemoteImagePasteController(
            worklaneStore: WorklaneStore(),
            runtimeRegistry: PaneRuntimeRegistry(),
            uploader: RemoteImageUploader(),
            sshProcessProbe: PaneSSHProcessProbe(),
            toasts: WindowToastPresenter(
                hostViewProvider: { nil },
                themeProvider: { ZenttyTheme.fallback(for: nil) }
            )
        )
    }

    func test_destination_uses_remote_shell_context_when_title_and_ssh_label_are_missing() throws {
        let shellContext = PaneShellContext(
            scope: .remote,
            path: "/srv/app",
            home: "/home/peter",
            user: "peter",
            host: "prod-box"
        )
        let auxiliaryState = PaneAuxiliaryState(
            raw: PaneRawState(shellContext: shellContext),
            presentation: PanePresentationNormalizer.normalize(
                paneTitle: "zsh",
                raw: PaneRawState(shellContext: shellContext),
                previous: nil
            )
        )

        let destination = try XCTUnwrap(PaneSSHDestinationResolver.destination(from: auxiliaryState))
        XCTAssertEqual(destination.target, "peter@prod-box")
        XCTAssertEqual(destination.user, "peter")
        XCTAssertEqual(destination.host, "prod-box")
        XCTAssertNil(destination.port)
    }

    func test_destination_prefers_process_probe_over_title_derived_destination() throws {
        let raw = PaneRawState(
            metadata: TerminalMetadata(title: "ssh stale@example.test", processName: "ssh"),
            foregroundSSHDestination: SSHDestination(
                target: "peter@live.example.test",
                user: "peter",
                host: "live.example.test",
                port: 2222
            )
        )
        let auxiliaryState = PaneAuxiliaryState(
            raw: raw,
            presentation: PanePresentationNormalizer.normalize(
                paneTitle: "ssh stale@example.test",
                raw: raw,
                previous: nil
            )
        )

        let destination = try XCTUnwrap(PaneSSHDestinationResolver.destination(from: auxiliaryState))

        XCTAssertEqual(destination.target, "peter@live.example.test")
        XCTAssertEqual(destination.user, "peter")
        XCTAssertEqual(destination.host, "live.example.test")
        XCTAssertEqual(destination.port, 2222)
    }

    func test_destination_falls_back_to_title_when_probe_is_nil() throws {
        let raw = PaneRawState(
            metadata: TerminalMetadata(title: "ssh -p 2200 stale@example.test", processName: "ssh"),
            foregroundSSHDestination: nil
        )
        let auxiliaryState = PaneAuxiliaryState(
            raw: raw,
            presentation: PanePresentationNormalizer.normalize(
                paneTitle: "ssh -p 2200 stale@example.test",
                raw: raw,
                previous: nil
            )
        )

        let destination = try XCTUnwrap(PaneSSHDestinationResolver.destination(from: auxiliaryState))

        XCTAssertEqual(destination.target, "stale@example.test")
        XCTAssertEqual(destination.user, "stale")
        XCTAssertEqual(destination.host, "example.test")
        XCTAssertEqual(destination.port, 2200)
    }

    func test_remote_image_data_uploads() {
        XCTAssertTrue(
            RemoteImagePasteDecision.shouldUploadRemotely(
                paneState: RemoteImagePastePaneState(isRemotePane: true, destination: SSHDestination(target: "host")),
                pasteboardContents: .imageData
            )
        )
    }

    func test_remote_text_does_not_upload() {
        XCTAssertFalse(
            RemoteImagePasteDecision.shouldUploadRemotely(
                paneState: RemoteImagePastePaneState(isRemotePane: true, destination: SSHDestination(target: "host")),
                pasteboardContents: .text
            )
        )
    }

    func test_local_image_data_does_not_upload() {
        XCTAssertFalse(
            RemoteImagePasteDecision.shouldUploadRemotely(
                paneState: RemoteImagePastePaneState(isRemotePane: false, destination: nil),
                pasteboardContents: .imageData
            )
        )
    }

    func test_local_pane_without_probe_destination_stays_local() {
        let raw = PaneRawState(
            metadata: TerminalMetadata(title: "~/app", processName: "zsh"),
            foregroundSSHDestination: nil
        )
        let presentation = PanePresentationNormalizer.normalize(
            paneTitle: "shell",
            raw: raw,
            previous: nil
        )
        let paneState = RemoteImagePastePaneState(
            isRemotePane: presentation.isRemotePane,
            destination: PaneSSHDestinationResolver.destination(
                from: PaneAuxiliaryState(raw: raw, presentation: presentation)
            )
        )

        XCTAssertFalse(
            RemoteImagePasteDecision.shouldUploadRemotely(
                paneState: paneState,
                pasteboardContents: .imageData
            )
        )
        XCTAssertNil(paneState.destination)
    }

    func test_remote_file_urls_upload_regardless_of_type() {
        XCTAssertTrue(
            RemoteImagePasteDecision.shouldUploadRemotely(
                paneState: RemoteImagePastePaneState(isRemotePane: true, destination: SSHDestination(target: "host")),
                pasteboardContents: .fileURL
            )
        )
    }

    func test_local_file_urls_do_not_upload() {
        XCTAssertFalse(
            RemoteImagePasteDecision.shouldUploadRemotely(
                paneState: RemoteImagePastePaneState(isRemotePane: false, destination: nil),
                pasteboardContents: .fileURL
            )
        )
    }
}
