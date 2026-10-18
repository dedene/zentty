import Foundation

/// Builds the variable table `TmuxFormatRenderer` renders against for one
/// pane, window or session of a `TmuxTopology`.
enum TmuxFormatContext {
    static let version = TmuxCommandLine.version

    /// Options tools read back with `show-options` or `#{option}` before
    /// they ever set them. Values match tmux's defaults where it matters to
    /// callers: `mouse`/`focus-events` off keeps agent TUIs on their plain
    /// input path.
    static let defaultOptions: [String: String] = [
        "base-index": "0",
        "pane-base-index": "0",
        "focus-events": "off",
        "mouse": "off",
        "synchronize-panes": "off",
        "remain-on-exit": "off",
        "set-clipboard": "external",
        "extended-keys": "off",
        "prefix": "C-b",
        "default-terminal": "tmux-256color",
        "escape-time": "10",
    ]

    static func session(
        _ topology: TmuxTopology,
        host: String = TmuxFormatContext.hostName()
    ) -> [String: String] {
        let session = topology.session
        let hostShort = host.split(separator: ".").first.map(String.init) ?? host
        return [
            "session_name": session.name,
            "session_id": "$\(session.number)",
            "session_created": String(session.created),
            "session_windows": String(session.windows.count),
            "session_attached": "1",
            "session_many_attached": "0",
            "socket_path": topology.socketPath,
            "pid": String(topology.serverPID),
            "version": version,
            "host": host,
            "host_short": hostShort,
            "client_control_mode": "0",
            "client_termtype": "xterm-ghostty",
            "client_name": "zentty",
            "client_tty": "",
        ]
    }

    static func window(
        _ window: TmuxTopology.Window,
        in topology: TmuxTopology,
        host: String = TmuxFormatContext.hostName()
    ) -> [String: String] {
        var context = session(topology, host: host)
        context["window_id"] = "@\(window.number)"
        context["window_uuid"] = window.id
        context["window_index"] = String(window.index)
        context["window_name"] = window.name
        context["window_active"] = window.isActive ? "1" : "0"
        context["window_panes"] = String(window.panes.count)
        context["window_width"] = String(window.columns)
        context["window_height"] = String(window.rows)
        context["window_flags"] = window.isActive ? "*" : ""
        context["window_zoomed_flag"] = "0"
        return context
    }

    static func pane(
        _ pane: TmuxTopology.Pane,
        window: TmuxTopology.Window,
        in topology: TmuxTopology,
        options: [String: String] = [:],
        currentCommand: String? = nil,
        host: String = TmuxFormatContext.hostName()
    ) -> [String: String] {
        var context = Self.window(window, in: topology, host: host)
        for (name, value) in defaultOptions {
            context[name] = value
        }
        for (name, value) in options {
            context[name] = value
        }
        context["pane_id"] = "%\(pane.number)"
        context["pane_uuid"] = pane.id
        context["pane_index"] = String(pane.index)
        context["pane_title"] = pane.title
        context["pane_active"] = pane.isActive ? "1" : "0"
        context["pane_current_path"] = pane.workingDirectory ?? ""
        context["pane_pid"] = pane.pid.map(String.init) ?? ""
        context["pane_dead"] = "0"
        context["pane_dead_status"] = ""
        context["pane_in_mode"] = "0"
        context["pane_mode"] = ""
        context["pane_width"] = String(pane.columns)
        context["pane_height"] = String(pane.rows)
        context["pane_left"] = String(pane.left)
        context["pane_top"] = String(pane.top)
        context["pane_right"] = String(pane.left + max(pane.columns, 1) - 1)
        context["pane_bottom"] = String(pane.top + max(pane.rows, 1) - 1)
        context["pane_start_command"] = pane.startCommand
        context["pane_current_command"] = currentCommand ?? ""
        context["pane_tty"] = ""
        context["pane_synchronized"] = "0"
        context["cursor_x"] = "0"
        context["cursor_y"] = "0"
        return context
    }

    /// `gethostname` rather than `ProcessInfo.hostName`, which can block on
    /// a reverse DNS lookup.
    static func hostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else {
            return "localhost"
        }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
