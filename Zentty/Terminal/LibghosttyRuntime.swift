import AppKit
import GhosttyKit
import UniformTypeIdentifiers

enum LibghosttySurfaceActionPayload: Equatable {
    case setTitle(String?)
    case pwd(String?)
    case commandFinished(exitCode: Int?, durationNanoseconds: UInt64)
}

func copyLibghosttySurfaceActionPayload(from action: ghostty_action_s) -> LibghosttySurfaceActionPayload? {
    switch action.tag {
    case GHOSTTY_ACTION_SET_TITLE:
        let title = action.action.set_title.title.map { String(cString: $0) }
        return .setTitle(title)
    case GHOSTTY_ACTION_PWD:
        let pwd = action.action.pwd.pwd.map { String(cString: $0) }
        return .pwd(pwd)
    case GHOSTTY_ACTION_COMMAND_FINISHED:
        let rawExitCode = Int(action.action.command_finished.exit_code)
        let exitCode = rawExitCode >= 0 ? rawExitCode : nil
        return .commandFinished(
            exitCode: exitCode,
            durationNanoseconds: action.action.command_finished.duration
        )
    default:
        return nil
    }
}

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
    guard let payload = copyLibghosttySurfaceActionPayload(from: action) else {
        return false
    }

    DispatchQueue.main.async {
        owner.handle(payload: payload)
    }

    return true
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

        var runtimeConfig = Self.makeRuntimeConfig(
            userdata: Unmanaged.passUnretained(self).toOpaque()
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
        request: TerminalSessionRequest,
        configTemplate: ghostty_surface_config_s?,
        metadataDidChange: @escaping (TerminalMetadata) -> Void,
        eventDidOccur: @escaping (TerminalEvent) -> Void
    ) throws -> any LibghosttySurfaceControlling {
        guard let app else {
            throw Error.appCreationFailed
        }

        return try LibghosttySurface(
            app: app,
            hostView: hostView,
            request: request,
            configTemplate: configTemplate,
            metadataDidChange: metadataDidChange,
            eventDidOccur: eventDidOccur
        )
    }

    static func makeRuntimeConfig(userdata: UnsafeMutableRawPointer?) -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: userdata,
            supports_selection_clipboard: true,
            wakeup_cb: libghosttyWakeupCallback,
            action_cb: libghosttyActionCallback,
            read_clipboard_cb: libghosttyReadClipboardCallback,
            confirm_read_clipboard_cb: libghosttyConfirmReadClipboardCallback,
            write_clipboard_cb: libghosttyWriteClipboardCallback,
            close_surface_cb: nil
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

private func libghosttyReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    state: UnsafeMutableRawPointer?
) -> Bool {
    guard
        let userdata,
        let surface = Unmanaged<LibghosttySurface>.fromOpaque(userdata).takeUnretainedValue().surface,
        let pasteboard = NSPasteboard.ghostty(location),
        let string = pasteboard.getOpinionatedStringContents()
    else {
        return false
    }

    string.withCString { pointer in
        ghostty_surface_complete_clipboard_request(surface, pointer, state, false)
    }
    return true
}

private func libghosttyConfirmReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    string: UnsafePointer<CChar>?,
    state: UnsafeMutableRawPointer?,
    _: ghostty_clipboard_request_e
) {
    guard
        let userdata,
        let surface = Unmanaged<LibghosttySurface>.fromOpaque(userdata).takeUnretainedValue().surface,
        let string
    else {
        return
    }

    ghostty_surface_complete_clipboard_request(surface, string, state, true)
}

private func libghosttyWriteClipboardCallback(
    _: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    content: UnsafePointer<ghostty_clipboard_content_s>?,
    len: Int,
    _: Bool
) {
    guard let pasteboard = NSPasteboard.ghostty(location), let content, len > 0 else {
        return
    }

    let entries = (0..<len).compactMap { index -> (mime: String, data: String)? in
        guard
            let mime = content[index].mime,
            let data = content[index].data
        else {
            return nil
        }

        return (String(cString: mime), String(cString: data))
    }
    guard entries.isEmpty == false else {
        return
    }

    let types = entries.compactMap { NSPasteboard.PasteboardType(mimeType: $0.mime) }
    pasteboard.declareTypes(types, owner: nil)

    for entry in entries {
        guard let type = NSPasteboard.PasteboardType(mimeType: entry.mime) else {
            continue
        }
        pasteboard.setString(entry.data, forType: type)
    }
}

private extension NSPasteboard.PasteboardType {
    init?(mimeType: String) {
        switch mimeType {
        case "text/plain":
            self = .string
            return
        default:
            break
        }

        guard let type = UTType(mimeType: mimeType) else {
            self.init(mimeType)
            return
        }

        self.init(type.identifier)
    }
}

private extension NSPasteboard {
    static var zenttySelection: NSPasteboard {
        NSPasteboard(name: .init("com.peterdedene.zentty.selection"))
    }

    static func ghostty(_ clipboard: ghostty_clipboard_e) -> NSPasteboard? {
        switch clipboard {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return .general
        case GHOSTTY_CLIPBOARD_SELECTION:
            return zenttySelection
        default:
            return nil
        }
    }

    func getOpinionatedStringContents() -> String? {
        if let urls = readObjects(forClasses: [NSURL.self]) as? [URL], urls.isEmpty == false {
            return urls
                .map { $0.isFileURL ? $0.path : $0.absoluteString }
                .joined(separator: " ")
        }

        return string(forType: .string)
    }
}
