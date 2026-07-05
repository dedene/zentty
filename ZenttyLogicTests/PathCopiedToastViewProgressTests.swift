import AppKit
import XCTest
@testable import Zentty

@MainActor
final class PathCopiedToastViewProgressTests: AppKitTestCase {
    func test_progress_mode_updates_message_and_fraction() {
        let parentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        let toast = PathCopiedToastView()

        let handle = toast.beginProgress(
            message: "Uploading pasted image (0%)",
            in: parentView,
            theme: ZenttyTheme.fallback(for: nil)
        )
        handle.updateProgress(fraction: 0.42, message: "Uploading pasted image (42%)")

        XCTAssertTrue(toast.isProgressActiveForTesting)
        XCTAssertEqual(toast.messageForTesting, "Uploading pasted image (42%)")
        XCTAssertEqual(toast.progressFractionForTesting, 0.42, accuracy: 0.001)
    }

    func test_progress_finish_switches_to_success_message() {
        let parentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        let toast = PathCopiedToastView()

        let handle = toast.beginProgress(
            message: "Uploading pasted image (0%)",
            in: parentView,
            theme: ZenttyTheme.fallback(for: nil)
        )
        handle.finish(message: "Pasted remote path", icon: "checkmark.circle.fill")

        XCTAssertFalse(toast.isProgressActiveForTesting)
        XCTAssertEqual(toast.messageForTesting, "Pasted remote path")
        XCTAssertEqual(toast.iconSymbolNameForTesting, "checkmark.circle.fill")
    }

    func test_progress_failure_switches_to_error_message() {
        let parentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        let toast = PathCopiedToastView()

        let handle = toast.beginProgress(
            message: "Uploading pasted image (0%)",
            in: parentView,
            theme: ZenttyTheme.fallback(for: nil)
        )
        handle.fail(message: "Couldn't upload image — ssh key auth required")

        XCTAssertFalse(toast.isProgressActiveForTesting)
        XCTAssertEqual(toast.messageForTesting, "Couldn't upload image — ssh key auth required")
        XCTAssertEqual(toast.iconSymbolNameForTesting, "xmark.circle.fill")
    }

    func test_progress_temporary_message_restores_latest_progress_message() async throws {
        let parentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        let toast = PathCopiedToastView()

        let handle = toast.beginProgress(
            message: "Uploading pasted image (0%)",
            in: parentView,
            theme: ZenttyTheme.fallback(for: nil)
        )
        toast.temporarilyShowProgressMessage("Upload already in progress", duration: 0.01)
        handle.updateProgress(fraction: 0.42, message: "Uploading pasted image (42%)")

        XCTAssertEqual(toast.messageForTesting, "Upload already in progress")

        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(toast.messageForTesting, "Uploading pasted image (42%)")
        XCTAssertEqual(toast.progressFractionForTesting, 0.42, accuracy: 0.001)
    }
}
