import AppKit

@MainActor
enum TerminalAdapterRegistry {
    private static var factory: @MainActor () -> any TerminalAdapter = {
        LibghosttyAdapter()
    }

    static func makeAdapter() -> any TerminalAdapter {
        factory()
    }

    static func useLibghosttyAdapters() {
        factory = {
            LibghosttyAdapter()
        }
    }

    static func useMockAdapters() {
        factory = {
            MockTerminalAdapter()
        }
    }
}
