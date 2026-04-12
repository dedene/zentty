import Foundation

struct OpenCodeOverlayRoots: Equatable {
    let toolDirectoryURL: URL
    let configHomeURL: URL
    let configDirectoryURL: URL
    let stateHomeURL: URL
    let stateDirectoryURL: URL
}

enum OpenCodeOverlayLayout {
    static func toolDirectoryURL(
        runtimeDirectoryURL: URL,
        worklaneID: WorklaneID,
        paneID: PaneID
    ) -> URL {
        runtimeDirectoryURL
            .appendingPathComponent("launch", isDirectory: true)
            .appendingPathComponent(worklaneID.rawValue, isDirectory: true)
            .appendingPathComponent(paneID.rawValue, isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
    }

    static func overlayRoots(
        runtimeDirectoryURL: URL,
        worklaneID: WorklaneID,
        paneID: PaneID
    ) -> OpenCodeOverlayRoots {
        overlayRoots(
            for: toolDirectoryURL(
                runtimeDirectoryURL: runtimeDirectoryURL,
                worklaneID: worklaneID,
                paneID: paneID
            )
        )
    }

    static func overlayRoots(for toolDirectoryURL: URL) -> OpenCodeOverlayRoots {
        let configHomeURL = toolDirectoryURL.appendingPathComponent("xdg-config-home", isDirectory: true)
        let stateHomeURL = toolDirectoryURL.appendingPathComponent("xdg-state-home", isDirectory: true)
        return OpenCodeOverlayRoots(
            toolDirectoryURL: toolDirectoryURL,
            configHomeURL: configHomeURL,
            configDirectoryURL: configHomeURL.appendingPathComponent("opencode", isDirectory: true),
            stateHomeURL: stateHomeURL,
            stateDirectoryURL: stateHomeURL.appendingPathComponent("opencode", isDirectory: true)
        )
    }
}
