import AppKit
import GhosttyKit
import UniformTypeIdentifiers

enum LibghosttySurfaceActionPayload: Equatable {
    case setTitle(String?)
    case pwd(String?)
    case progressReport(TerminalProgressReport)
    case commandFinished(exitCode: Int?, durationNanoseconds: UInt64)
    case desktopNotification(TerminalDesktopNotification)
    case startSearch(String?)
    case endSearch
    case searchTotal(Int)
    case searchSelected(Int)
    case scrollbar(total: UInt64, offset: UInt64, len: UInt64)
    case openURL(String)
    case mouseShape(ghostty_action_mouse_shape_e)
}

func copyLibghosttySurfaceActionPayload(from action: ghostty_action_s) -> LibghosttySurfaceActionPayload? {
    switch action.tag {
    case GHOSTTY_ACTION_SET_TITLE:
        let title = action.action.set_title.title.map { String(cString: $0) }
        return .setTitle(title)
    case GHOSTTY_ACTION_PWD:
        let pwd = action.action.pwd.pwd.map { String(cString: $0) }
        return .pwd(pwd)
    case GHOSTTY_ACTION_PROGRESS_REPORT:
        let report = action.action.progress_report
        let progress = report.progress >= 0 ? UInt8(clamping: Int(report.progress)) : nil
        let state: TerminalProgressReport.State
        switch report.state {
        case GHOSTTY_PROGRESS_STATE_REMOVE:
            state = .remove
        case GHOSTTY_PROGRESS_STATE_SET:
            state = .set
        case GHOSTTY_PROGRESS_STATE_ERROR:
            state = .error
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE:
            state = .indeterminate
        case GHOSTTY_PROGRESS_STATE_PAUSE:
            state = .pause
        default:
            return nil
        }
        return .progressReport(
            TerminalProgressReport(
                state: state,
                progress: progress
            )
        )
    case GHOSTTY_ACTION_COMMAND_FINISHED:
        let rawExitCode = Int(action.action.command_finished.exit_code)
        let exitCode = rawExitCode >= 0 ? rawExitCode : nil
        return .commandFinished(
            exitCode: exitCode,
            durationNanoseconds: action.action.command_finished.duration
        )
    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
        let notification = action.action.desktop_notification
        let title = notification.title.map { String(cString: $0) }
        let body = notification.body.map { String(cString: $0) }
        return .desktopNotification(TerminalDesktopNotification(title: title, body: body))
    case GHOSTTY_ACTION_START_SEARCH:
        let needle = action.action.start_search.needle.map { String(cString: $0) }
        return .startSearch(needle)
    case GHOSTTY_ACTION_END_SEARCH:
        return .endSearch
    case GHOSTTY_ACTION_SEARCH_TOTAL:
        return .searchTotal(Int(action.action.search_total.total))
    case GHOSTTY_ACTION_SEARCH_SELECTED:
        return .searchSelected(Int(action.action.search_selected.selected))
    case GHOSTTY_ACTION_SCROLLBAR:
        let s = action.action.scrollbar
        return .scrollbar(total: s.total, offset: s.offset, len: s.len)
    case GHOSTTY_ACTION_OPEN_URL:
        let openURL = action.action.open_url
        guard let urlPointer = openURL.url, openURL.len > 0 else {
            return nil
        }
        let data = Data(bytes: urlPointer, count: Int(openURL.len))
        guard let urlString = String(data: data, encoding: .utf8), !urlString.isEmpty else {
            return nil
        }
        return .openURL(urlString)
    case GHOSTTY_ACTION_MOUSE_SHAPE:
        return .mouseShape(action.action.mouse_shape)
    default:
        return nil
    }
}

private func libghosttyCloseSurfaceCallback(_ userdata: UnsafeMutableRawPointer?, _: Bool) {
    guard let userdata else {
        return
    }

    let surface = Unmanaged<LibghosttySurface>.fromOpaque(userdata).takeUnretainedValue()
    surface.notifySurfaceClosed()
}

final class LibghosttyWakeupCoordinator: @unchecked Sendable {
    typealias Scheduler = (@escaping @Sendable () -> Void) -> Void

    private let diagnostics: TerminalDiagnostics
    private let schedule: Scheduler
    private let tick: @Sendable () -> Void
    private let now: @Sendable () -> UInt64
    private let lock = NSLock()

    private var tickScheduledOrRunning = false
    private var wakeupRequestedWhileScheduled = false

    init(
        diagnostics: TerminalDiagnostics,
        schedule: @escaping Scheduler = { DispatchQueue.main.async(execute: $0) },
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        tick: @escaping @Sendable () -> Void
    ) {
        self.diagnostics = diagnostics
        self.schedule = schedule
        self.now = now
        self.tick = tick
    }

    func requestTick() {
        diagnostics.recordWakeupReceived()

        let enqueuedAt = now()
        let shouldSchedule: Bool
        lock.lock()
        if tickScheduledOrRunning {
            wakeupRequestedWhileScheduled = true
            shouldSchedule = false
        } else {
            tickScheduledOrRunning = true
            shouldSchedule = true
        }
        lock.unlock()

        guard shouldSchedule else {
            return
        }

        diagnostics.recordWakeupEnqueued()
        schedule { [weak self] in
            self?.runScheduledTick(enqueuedAt: enqueuedAt)
        }
    }

    private func runScheduledTick(enqueuedAt: UInt64) {
        let startedAt = now()
        tick()
        let finishedAt = now()
        diagnostics.recordTick(
            durationNanoseconds: finishedAt - startedAt,
            queueDelayNanoseconds: startedAt - enqueuedAt
        )

        let nextEnqueuedAt = now()
        let shouldScheduleAgain: Bool
        lock.lock()
        if wakeupRequestedWhileScheduled {
            wakeupRequestedWhileScheduled = false
            shouldScheduleAgain = true
        } else {
            tickScheduledOrRunning = false
            shouldScheduleAgain = false
        }
        lock.unlock()

        guard shouldScheduleAgain else {
            return
        }

        diagnostics.recordWakeupEnqueued()
        schedule { [weak self] in
            self?.runScheduledTick(enqueuedAt: nextEnqueuedAt)
        }
    }
}

private func libghosttyWakeupCallback(userdata: UnsafeMutableRawPointer?) {
    guard let userdata else {
        return
    }

    let runtime = Unmanaged<LibghosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    runtime.wakeupCoordinator.requestTick()
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
    owner.recordActionCallback(payload: payload)

    if owner.enqueue(payload: payload) {
        let enqueuedAt = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak owner] in
            let startedAt = DispatchTime.now().uptimeNanoseconds
            owner?.drainCoalescedActions(queueDelayNanoseconds: startedAt - enqueuedAt)
        }
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
    nonisolated let diagnostics: TerminalDiagnostics
    nonisolated(unsafe) var wakeupCoordinator: LibghosttyWakeupCoordinator
    private let configEnvironment: GhosttyConfigEnvironment

    private init(configEnvironment: GhosttyConfigEnvironment = GhosttyConfigEnvironment()) throws {
        self.app = nil
        self.config = nil
        self.diagnostics = .shared
        self.wakeupCoordinator = LibghosttyWakeupCoordinator(diagnostics: self.diagnostics) {}
        self.configEnvironment = configEnvironment

        Self.configureResourcesDirectoryIfNeeded()
        Self.configureLogLevelIfNeeded()

        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard initResult == GHOSTTY_SUCCESS else {
            throw Error.initializationFailed(initResult)
        }

        guard let config = ghostty_config_new() else {
            throw Error.configCreationFailed
        }

        Self.loadConfigStack(config, environment: configEnvironment)
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
        self.wakeupCoordinator = LibghosttyWakeupCoordinator(diagnostics: diagnostics) { [weak self] in
            guard let app = self?.app else {
                return
            }
            ghostty_app_tick(app)
        }
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
        paneID: PaneID,
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
            paneID: paneID,
            hostView: hostView,
            request: request,
            configTemplate: configTemplate,
            diagnostics: diagnostics,
            metadataDidChange: metadataDidChange,
            eventDidOccur: eventDidOccur
        )
    }

    func reloadConfig() {
        guard let app else {
            return
        }
        guard let newConfig = ghostty_config_new() else {
            return
        }
        Self.loadConfigStack(newConfig, environment: configEnvironment)
        ghostty_config_finalize(newConfig)
        ghostty_app_update_config(app, newConfig)
        let oldConfig = self.config
        self.config = newConfig
        if let oldConfig {
            ghostty_config_free(oldConfig)
        }
    }

    func applyBackgroundBlur(to window: NSWindow) {
        guard let app else { return }
        ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque())
    }

    private static let localOverridePath = NSTemporaryDirectory() + "zentty-ghostty-local-overrides.conf"
    private static let transparentOverridePath = NSTemporaryDirectory() + "zentty-ghostty-transparent-override.conf"

    private static func loadConfigStack(_ config: ghostty_config_t, environment: GhosttyConfigEnvironment) {
        let stack = environment.resolvedStack()

        for url in stack?.loadFiles ?? [] {
            url.path.withCString { pointer in
                ghostty_config_load_file(config, pointer)
            }
        }

        if stack?.writeTargetURL != nil {
            ghostty_config_load_recursive_files(config)
        }

        if let localOverrideContents = stack?.localOverrideContents {
            loadConfigFile(contents: localOverrideContents, path: localOverridePath, into: config)
        }

        loadTransparentBackgroundOverride(
            config,
            userConfigContents: stack?.mergedUserConfigContents()
        )
    }

    private static func loadTransparentBackgroundOverride(
        _ config: ghostty_config_t,
        userConfigContents: String?
    ) {
        guard let lines = transparentBackgroundOverrideContents(
            userConfigContents: userConfigContents
        ) else {
            return
        }

        loadConfigFile(contents: lines, path: transparentOverridePath, into: config)
    }

    private static func loadConfigFile(contents: String, path: String, into config: ghostty_config_t) {
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        path.withCString { pointer in
            ghostty_config_load_file(config, pointer)
        }
    }

    static func transparentBackgroundOverrideContents(userConfigContents: String?) -> String? {
        var lines = "background-opacity = 0\n"

        guard !userConfigContainsBackgroundBlur(userConfigContents) else {
            return lines
        }

        lines += "background-blur-radius = 20\n"
        return lines
    }

    private static func userConfigContainsBackgroundBlur(_ content: String?) -> Bool {
        guard let content else {
            return false
        }

        return content.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//") else { return false }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            let key = parts.first?.trimmingCharacters(in: .whitespaces)
            return key == "background-blur" || key == "background-blur-radius"
        }
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
            close_surface_cb: libghosttyCloseSurfaceCallback
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

    private static func configureLogLevelIfNeeded() {
        guard getenv("GHOSTTY_LOG") == nil else {
            return
        }
        setenv("GHOSTTY_LOG", "macos,no-stderr", 1)
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
        let content = TerminalClipboard.pastedContent(from: pasteboard)
    else {
        return false
    }

    let string: String
    switch content {
    case .text(let text):
        string = text
    case .filePath(let path):
        string = path
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
        NSPasteboard(name: .init("be.zenjoy.zentty.selection"))
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
}
