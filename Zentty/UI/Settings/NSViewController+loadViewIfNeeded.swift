import AppKit

extension NSViewController {
    @MainActor
    func backwardCompatibleLoadViewIfNeeded() {
        if #available(macOS 14.0, *) {
            _ = view
        } else {
            _ = view
        }
    }
}
