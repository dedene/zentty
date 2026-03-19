import AppKit

#if DEBUG
@MainActor
enum TerminalAdapterRegistry {
    private static var factory: @MainActor () -> any TerminalAdapter = {
        LibghosttyAdapter()
    }

    static func makeAdapter() -> any TerminalAdapter {
        factory()
    }

    static func useMockAdapters() {
        factory = {
            MockTerminalAdapter()
        }
    }
}
#endif
