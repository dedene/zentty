import Foundation

struct AgentStatusCommand {
    let payload: AgentStatusPayload

    static func parse(arguments: [String], environment: [String: String]) throws -> AgentStatusCommand {
        let trimmedArguments: ArraySlice<String>
        if arguments.dropFirst().first == "agent-status" {
            trimmedArguments = arguments.dropFirst(2)
        } else {
            trimmedArguments = arguments.dropFirst()
        }

        guard let verb = trimmedArguments.first else {
            throw AgentStatusPayloadError.invalidArguments("Missing status verb.")
        }

        let state: PaneAgentState?
        switch verb {
        case PaneAgentState.running.rawValue:
            state = .running
        case PaneAgentState.needsInput.rawValue:
            state = .needsInput
        case PaneAgentState.completed.rawValue:
            state = .completed
        case "clear":
            state = nil
        default:
            throw AgentStatusPayloadError.invalidArguments("Unsupported status verb: \(verb)")
        }

        let options = try parseOptions(Array(trimmedArguments.dropFirst()))
        guard let workspaceID = options["workspace-id"] ?? environment["ZENTTY_WORKSPACE_ID"] else {
            throw AgentStatusPayloadError.missingWorkspaceID
        }
        guard let paneID = options["pane-id"] ?? environment["ZENTTY_PANE_ID"] else {
            throw AgentStatusPayloadError.missingPaneID
        }

        return AgentStatusCommand(
            payload: AgentStatusPayload(
                workspaceID: WorkspaceID(workspaceID),
                paneID: PaneID(paneID),
                signalKind: .lifecycle,
                state: state,
                origin: .compatibility,
                toolName: options["tool"],
                text: options["text"],
                artifactKind: options["artifact-kind"].flatMap(WorkspaceArtifactKind.init(rawValue:)),
                artifactLabel: options["artifact-label"],
                artifactURL: try parseArtifactURL(from: options["artifact-url"])
            )
        )
    }

    fileprivate static func parseOptions(_ arguments: [String]) throws -> [String: String] {
        var index = 0
        var options: [String: String] = [:]

        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--") else {
                throw AgentStatusPayloadError.invalidArguments("Unexpected argument: \(key)")
            }
            let optionName = String(key.dropFirst(2))
            let valueIndex = index + 1
            guard arguments.indices.contains(valueIndex) else {
                throw AgentStatusPayloadError.invalidArguments("Missing value for \(key)")
            }
            options[optionName] = arguments[valueIndex]
            index += 2
        }

        return options
    }

    fileprivate static func parseArtifactURL(from rawValue: String?) throws -> URL? {
        guard let rawValue else {
            return nil
        }
        guard let url = URL(string: rawValue) else {
            throw AgentStatusPayloadError.invalidArtifactURL(rawValue)
        }
        return url
    }
}

struct AgentSignalCommand {
    let payload: AgentStatusPayload

    static func parse(arguments: [String], environment: [String: String]) throws -> AgentSignalCommand {
        let trimmedArguments: ArraySlice<String>
        if arguments.dropFirst().first == "agent-signal" {
            trimmedArguments = arguments.dropFirst(2)
        } else {
            trimmedArguments = arguments.dropFirst()
        }

        guard let rawKind = trimmedArguments.first,
              let kind = AgentSignalKind(rawValue: rawKind) else {
            throw AgentStatusPayloadError.invalidArguments("Missing or invalid signal kind.")
        }

        let (positionals, options) = try parsePositionalsAndOptions(Array(trimmedArguments.dropFirst()))
        guard let workspaceID = options["workspace-id"] ?? environment["ZENTTY_WORKSPACE_ID"] else {
            throw AgentStatusPayloadError.missingWorkspaceID
        }
        guard let paneID = options["pane-id"] ?? environment["ZENTTY_PANE_ID"] else {
            throw AgentStatusPayloadError.missingPaneID
        }

        let origin = options["origin"].flatMap(AgentSignalOrigin.init(rawValue:)) ?? defaultOrigin(for: kind)

        switch kind {
        case .lifecycle:
            guard let verb = positionals.first else {
                throw AgentStatusPayloadError.missingState
            }

            let state: PaneAgentState?
            switch verb {
            case PaneAgentState.running.rawValue:
                state = .running
            case PaneAgentState.needsInput.rawValue:
                state = .needsInput
            case PaneAgentState.completed.rawValue:
                state = .completed
            case "clear":
                state = nil
            default:
                throw AgentStatusPayloadError.invalidArguments("Unsupported lifecycle state: \(verb)")
            }

            return AgentSignalCommand(
                payload: AgentStatusPayload(
                    workspaceID: WorkspaceID(workspaceID),
                    paneID: PaneID(paneID),
                    signalKind: .lifecycle,
                    state: state,
                    origin: origin,
                    toolName: options["tool"],
                    text: options["text"],
                    artifactKind: options["artifact-kind"].flatMap(WorkspaceArtifactKind.init(rawValue:)),
                    artifactLabel: options["artifact-label"],
                    artifactURL: try AgentStatusCommand.parseArtifactURL(from: options["artifact-url"])
                )
            )
        case .shellState:
            guard let rawState = positionals.first else {
                throw AgentStatusPayloadError.invalidArguments("Missing shell state.")
            }

            let shellActivityState: PaneShellActivityState
            switch rawState {
            case "prompt", "idle":
                shellActivityState = .promptIdle
            case "running", "busy", "command":
                shellActivityState = .commandRunning
            case "clear", "unknown":
                shellActivityState = .unknown
            default:
                throw AgentStatusPayloadError.invalidArguments("Unsupported shell state: \(rawState)")
            }

            return AgentSignalCommand(
                payload: AgentStatusPayload(
                    workspaceID: WorkspaceID(workspaceID),
                    paneID: PaneID(paneID),
                    signalKind: .shellState,
                    state: nil,
                    shellActivityState: shellActivityState,
                    origin: origin,
                    toolName: options["tool"],
                    text: nil,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                )
            )
        case .pid:
            guard let rawEvent = positionals.first,
                  let pidEvent = AgentPIDSignalEvent(rawValue: rawEvent) else {
                throw AgentStatusPayloadError.invalidArguments("Missing or invalid pid event.")
            }

            let pid: Int32?
            switch pidEvent {
            case .attach:
                guard positionals.count >= 2,
                      let parsedPID = Int32(positionals[1]),
                      parsedPID > 0 else {
                    throw AgentStatusPayloadError.missingPID
                }
                pid = parsedPID
            case .clear:
                pid = nil
            }

            return AgentSignalCommand(
                payload: AgentStatusPayload(
                    workspaceID: WorkspaceID(workspaceID),
                    paneID: PaneID(paneID),
                    signalKind: .pid,
                    state: nil,
                    pid: pid,
                    pidEvent: pidEvent,
                    origin: origin,
                    toolName: options["tool"],
                    text: nil,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                )
            )
        case .paneContext:
            guard let rawScope = positionals.first else {
                throw AgentStatusPayloadError.invalidArguments("Missing pane context scope.")
            }

            if rawScope == "clear" {
                return AgentSignalCommand(
                    payload: AgentStatusPayload(
                        workspaceID: WorkspaceID(workspaceID),
                        paneID: PaneID(paneID),
                        signalKind: .paneContext,
                        state: nil,
                        paneContext: nil,
                        origin: origin,
                        toolName: nil,
                        text: nil,
                        artifactKind: nil,
                        artifactLabel: nil,
                        artifactURL: nil
                    )
                )
            }

            guard let scope = PaneShellContextScope(rawValue: rawScope) else {
                throw AgentStatusPayloadError.invalidArguments("Unsupported pane context scope: \(rawScope)")
            }

            return AgentSignalCommand(
                payload: AgentStatusPayload(
                    workspaceID: WorkspaceID(workspaceID),
                    paneID: PaneID(paneID),
                    signalKind: .paneContext,
                    state: nil,
                    paneContext: PaneShellContext(
                        scope: scope,
                        path: options["path"],
                        home: options["home"],
                        user: options["user"],
                        host: options["host"],
                        gitBranch: options["git-branch"]
                    ),
                    origin: origin,
                    toolName: nil,
                    text: nil,
                    artifactKind: nil,
                    artifactLabel: nil,
                    artifactURL: nil
                )
            )
        }
    }

    private static func parsePositionalsAndOptions(_ arguments: [String]) throws -> ([String], [String: String]) {
        var positionals: [String] = []
        var options: [String: String] = [:]
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let optionName = String(argument.dropFirst(2))
                let valueIndex = index + 1
                guard arguments.indices.contains(valueIndex) else {
                    throw AgentStatusPayloadError.invalidArguments("Missing value for \(argument)")
                }
                options[optionName] = arguments[valueIndex]
                index += 2
            } else {
                positionals.append(argument)
                index += 1
            }
        }

        return (positionals, options)
    }

    private static func defaultOrigin(for kind: AgentSignalKind) -> AgentSignalOrigin {
        switch kind {
        case .lifecycle:
            return .compatibility
        case .shellState:
            return .shell
        case .pid:
            return .explicitAPI
        case .paneContext:
            return .shell
        }
    }
}
