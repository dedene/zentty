import Foundation

extension TaskRunnerSourceScanner {
    func scanVSCodeTasks() throws -> [TaskRunnerAction] {
        let url = sourceRoot.appendingPathComponent(".vscode/tasks.json")
        guard fileManager.fileExists(atPath: url.path) else { return [] }

        let data = try Data(contentsOf: url)
        let relaxed = JSONCRelaxedParse.stripComments(in: data)
            .flatMap(JSONCRelaxedParse.stripTrailingCommas(in:)) ?? data
        guard let root = try JSONSerialization.jsonObject(with: relaxed) as? [String: Any],
              let tasks = root["tasks"] as? [[String: Any]]
        else {
            return []
        }

        return tasks.compactMap { rawTask in
            let task = mergeVSCodeTask(rawTask)
            guard let title = task["label"] as? String, !title.isEmpty else { return nil }
            guard let commandText = task["command"] as? String, !commandText.isEmpty else {
                return vscodeAction(
                    title: title,
                    sourcePath: url,
                    executionCommand: "",
                    environment: [:],
                    disabledReason: .unsupported("VS Code task has no runnable command")
                )
            }

            let args = (task["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            let rawCommand = ([commandText] + args.map(TaskRunnerShellQuoter.quote)).joined(separator: " ")
            let variableIssue = unsupportedVSCodeVariable(in: [commandText] + args)
                ?? unsupportedVSCodeVariable(in: vscodeEnvironment(task).map { "\($0.key)=\($0.value)" })
            let resolvedCommand = resolveVSCodeVariables(in: rawCommand)
            let disabledReason = variableIssue.map(TaskRunnerDisabledReason.unsupported)

            return vscodeAction(
                title: title,
                sourcePath: url,
                executionCommand: resolvedCommand,
                environment: vscodeEnvironment(task),
                disabledReason: disabledReason
            )
        }
    }

    func scanJustfile() throws -> [TaskRunnerAction] {
        let candidates = ["justfile", ".justfile", "Justfile"]
            .map { sourceRoot.appendingPathComponent($0) }
        guard let url = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return []
        }

        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
        return lines.compactMap { line in
            guard let parsed = parseJustRecipe(line), !parsed.name.hasPrefix("_") else { return nil }
            let command = "just \(TaskRunnerShellQuoter.quote(parsed.name))"
            let disabledReason: TaskRunnerDisabledReason? = parsed.parameters.isEmpty
                ? nil
                : .unsupported("Task requires parameters: \(parsed.parameters.joined(separator: ", "))")
            return action(
                title: parsed.name,
                description: nil,
                sourceKind: .justfile,
                sourcePath: url,
                executionCommand: command,
                commandPreview: command,
                environment: [:],
                disabledReason: disabledReason
            )
        }
    }

    func scanMakefile() throws -> [TaskRunnerAction] {
        let candidates = ["Makefile", "makefile"]
            .map { sourceRoot.appendingPathComponent($0) }
        guard let url = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return []
        }

        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
        let parsed = parseMakeTargets(lines)
        return parsed.map { target in
            let command = "make \(TaskRunnerShellQuoter.quote(target.name))"
            return action(
                title: target.name,
                description: target.description,
                sourceKind: .makefile,
                sourcePath: url,
                executionCommand: command,
                commandPreview: command,
                environment: [:],
                disabledReason: nil
            )
        }
    }

    func scanMise() throws -> [TaskRunnerAction] {
        var actions: [TaskRunnerAction] = []

        let tomlURL = sourceRoot.appendingPathComponent("mise.toml")
        if fileManager.fileExists(atPath: tomlURL.path) {
            actions += try parseMiseTomlTasks(tomlURL).map { task in
                let command = "mise run \(TaskRunnerShellQuoter.quote(task.name))"
                return action(
                    title: task.name,
                    description: task.description,
                    sourceKind: .mise,
                    sourcePath: tomlURL,
                    executionCommand: command,
                    commandPreview: command,
                    environment: [:],
                    disabledReason: nil
                )
            }
        }

        for taskDirectory in [
            sourceRoot.appendingPathComponent("mise-tasks", isDirectory: true),
            sourceRoot.appendingPathComponent(".mise/tasks", isDirectory: true),
        ] {
            if let files = try? fileManager.contentsOfDirectory(
                at: taskDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                actions += files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                        return nil
                    }
                    let name = url.deletingPathExtension().lastPathComponent
                    let command = "mise run \(TaskRunnerShellQuoter.quote(name))"
                    return action(
                        title: name,
                        description: nil,
                        sourceKind: .mise,
                        sourcePath: url,
                        executionCommand: command,
                        commandPreview: command,
                        environment: [:],
                        disabledReason: nil
                    )
                }
            }
        }

        return actions
    }

    private func mergeVSCodeTask(_ task: [String: Any]) -> [String: Any] {
        guard let osx = task["osx"] as? [String: Any] else { return task }
        return task.merging(osx) { _, override in override }
    }

    private func vscodeEnvironment(_ task: [String: Any]) -> [String: String] {
        guard let options = task["options"] as? [String: Any],
              let env = options["env"] as? [String: Any]
        else {
            return [:]
        }
        return env.compactMapValues { $0 as? String }
    }

    private func vscodeAction(
        title: String,
        sourcePath: URL,
        executionCommand: String,
        environment: [String: String],
        disabledReason: TaskRunnerDisabledReason?
    ) -> TaskRunnerAction {
        action(
            title: title,
            description: nil,
            sourceKind: .vscodeTask,
            sourcePath: sourcePath,
            executionCommand: executionCommand,
            commandPreview: executionCommand,
            environment: environment,
            disabledReason: disabledReason
        )
    }

    private func unsupportedVSCodeVariable(in values: [String]) -> String? {
        let supported = ["${workspaceFolder}", "${cwd}"]
        for value in values {
            for match in variableMatches(in: value) where !supported.contains(match) {
                return "Unsupported VS Code variable: \(match)"
            }
        }
        return nil
    }

    private func variableMatches(in value: String) -> [String] {
        var matches: [String] = []
        var remainder = value[...]
        while let start = remainder.range(of: "${")?.lowerBound,
              let end = remainder[start...].firstIndex(of: "}") {
            matches.append(String(remainder[start...end]))
            remainder = remainder[remainder.index(after: end)...]
        }
        return matches
    }

    private func resolveVSCodeVariables(in value: String) -> String {
        value
            .replacingOccurrences(of: "${workspaceFolder}", with: sourceRoot.path)
            .replacingOccurrences(of: "${cwd}", with: focusedWorkingDirectory)
    }
}

private func parseJustRecipe(_ line: String) -> (name: String, parameters: [String])? {
    guard line.first?.isWhitespace != true,
          !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
          let colonIndex = line.firstIndex(of: ":")
    else {
        return nil
    }

    let header = line[..<colonIndex]
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
    guard let name = header.first, !name.isEmpty else { return nil }
    return (name, Array(header.dropFirst()))
}

private func parseMakeTargets(_ lines: [String]) -> [(name: String, description: String?)] {
    var phonyOrder: [String] = []
    var descriptions: [String: String] = [:]
    var explicitHelpOrder: [String] = []

    for line in lines {
        if line.hasPrefix(".PHONY:") {
            phonyOrder += line
                .dropFirst(".PHONY:".count)
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            continue
        }

        guard line.first?.isWhitespace != true,
              let colonIndex = line.firstIndex(of: ":")
        else {
            continue
        }

        let name = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains(" ") else { continue }
        if let helpRange = line.range(of: "##") {
            descriptions[name] = String(line[helpRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            explicitHelpOrder.append(name)
        }
    }

    let names = (phonyOrder + explicitHelpOrder).removingDuplicates()
    return names.map { ($0, descriptions[$0]) }
}

private func parseMiseTomlTasks(_ url: URL) throws -> [(name: String, description: String?)] {
    let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
    var tasks: [(name: String, description: String?)] = []
    var currentName: String?
    var currentDescription: String?
    var section: String?

    func flush() {
        guard let currentName else { return }
        tasks.append((currentName, currentDescription))
    }

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[tasks."), trimmed.hasSuffix("]") {
            flush()
            currentName = String(trimmed.dropFirst("[tasks.".count).dropLast())
            currentDescription = nil
            section = nil
            continue
        }
        if trimmed.hasPrefix("[") {
            flush()
            currentName = nil
            currentDescription = nil
            section = String(trimmed.dropFirst().dropLast())
            continue
        }
        if section == "tasks",
           let equals = trimmed.firstIndex(of: "=") {
            let name = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                tasks.append((name, nil))
            }
            continue
        }
        if let currentName, !currentName.isEmpty,
           trimmed.hasPrefix("description"),
           let equals = trimmed.firstIndex(of: "=") {
            currentDescription = String(trimmed[trimmed.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }
    flush()
    return tasks
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
