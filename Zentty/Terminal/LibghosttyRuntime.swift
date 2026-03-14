import AppKit
import GhosttyKit

private func libghosttyWakeupCallback(userdata: UnsafeMutableRawPointer?) {
    guard let userdata else {
        return
    }

    let runtime = Unmanaged<LibghosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    let app = runtime.app

    DispatchQueue.main.async {
        guard let app else {
            return
        }
        ghostty_app_tick(app)
    }
}

private func libghosttyActionCallback(
    _: ghostty_app_t?,
    target: ghostty_target_s,
    action: ghostty_action_s
) -> Bool {
    guard target.tag == GHOSTTY_TARGET_SURFACE else {
        return false
    }

    guard let surface = target.target.surface,
          let userdata = ghostty_surface_userdata(surface) else {
        return false
    }

    let owner = Unmanaged<LibghosttySurface>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
        owner.handle(action: action)
    }

    switch action.tag {
    case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_PWD:
        return true
    default:
        return false
    }
}

@MainActor
final class LibghosttyRuntime: LibghosttyRuntimeProviding {
    enum Error: Swift.Error {
        case initializationFailed(Int32)
        case configCreationFailed
        case appCreationFailed
        case surfaceCreationFailed
    }

    static let shared: LibghosttyRuntime = {
        do {
            return try LibghosttyRuntime()
        } catch {
            fatalError("Failed to initialize libghostty runtime: \(error)")
        }
    }()

    nonisolated(unsafe) fileprivate var app: ghostty_app_t?
    nonisolated(unsafe) private var config: ghostty_config_t?

    private init() throws {
        self.app = nil
        self.config = nil

        Self.configureResourcesDirectoryIfNeeded()

        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard initResult == GHOSTTY_SUCCESS else {
            throw Error.initializationFailed(initResult)
        }

        guard let config = ghostty_config_new() else {
            throw Error.configCreationFailed
        }

        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        self.config = config

        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: libghosttyWakeupCallback,
            action_cb: libghosttyActionCallback,
            read_clipboard_cb: nil,
            confirm_read_clipboard_cb: nil,
            write_clipboard_cb: nil,
            close_surface_cb: nil
        )

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            ghostty_config_free(config)
            throw Error.appCreationFailed
        }

        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let app {
            ghostty_app_free(app)
        }
        if let config {
            ghostty_config_free(config)
        }
    }

    func makeSurface(
        for hostView: LibghosttyView,
        metadataDidChange: @escaping (TerminalMetadata) -> Void
    ) throws -> any LibghosttySurfaceControlling {
        guard let app else {
            throw Error.appCreationFailed
        }

        return try LibghosttySurface(
            app: app,
            hostView: hostView,
            metadataDidChange: metadataDidChange
        )
    }

    @objc
    private func applicationDidBecomeActive() {
        guard let app else {
            return
        }
        ghostty_app_set_focus(app, true)
    }

    @objc
    private func applicationDidResignActive() {
        guard let app else {
            return
        }
        ghostty_app_set_focus(app, false)
    }

    private static func configureResourcesDirectoryIfNeeded() {
        guard getenv("GHOSTTY_RESOURCES_DIR") == nil else {
            return
        }

        let fileManager = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("ghostty", isDirectory: true),
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Caches/zentty/ghostty-src/zig-out/share/ghostty", isDirectory: true),
        ]

        for case let candidate? in candidates where fileManager.fileExists(atPath: candidate.path) {
            setenv("GHOSTTY_RESOURCES_DIR", candidate.path, 1)
            return
        }
    }
}
