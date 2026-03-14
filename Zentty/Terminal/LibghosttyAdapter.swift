import AppKit

@MainActor
protocol LibghosttyRuntimeProviding: AnyObject {
    func makeSurface(
        for hostView: LibghosttyView,
        metadataDidChange: @escaping (TerminalMetadata) -> Void
    ) throws -> any LibghosttySurfaceControlling
}

@MainActor
protocol LibghosttySurfaceControlling: AnyObject {
    func updateViewport(size: CGSize, scale: CGFloat, displayID: UInt32?)
    func setFocused(_ isFocused: Bool)
    func refresh()
}

@MainActor
final class LibghosttyAdapter: TerminalAdapter {
    private let runtime: any LibghosttyRuntimeProviding
    private let hostView = LibghosttyView()
    private var surfaceController: (any LibghosttySurfaceControlling)?

    var metadataDidChange: ((TerminalMetadata) -> Void)?

    init(runtime: any LibghosttyRuntimeProviding = LibghosttyRuntime.shared) {
        self.runtime = runtime
    }

    func makeTerminalView() -> NSView {
        hostView
    }

    func startSession() throws {
        guard surfaceController == nil else {
            return
        }

        let surfaceController = try runtime.makeSurface(
            for: hostView,
            metadataDidChange: { [weak self] metadata in
                self?.metadataDidChange?(metadata)
            }
        )

        hostView.bind(surfaceController: surfaceController)
        self.surfaceController = surfaceController
    }
}
