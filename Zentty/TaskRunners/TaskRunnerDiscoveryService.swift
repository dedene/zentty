import Foundation

final class TaskRunnerDiscoveryService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func discover(focusedWorkingDirectory: String) throws -> [TaskRunnerAction] {
        let focusedURL = URL(fileURLWithPath: focusedWorkingDirectory)
        let ancestry = ancestryDirectories(from: focusedURL)

        let actions = ancestry.flatMap { sourceRoot in
            TaskRunnerSourceScanner(
                sourceRoot: sourceRoot,
                focusedWorkingDirectory: focusedURL.path,
                fileManager: fileManager
            ).scan()
        }
        return uniquedActions(actions)
    }

    private func ancestryDirectories(from focusedURL: URL) -> [URL] {
        var directories: [URL] = []
        var current = focusedURL.standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path

        while true {
            directories.append(current)
            if fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) {
                break
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.path != current.path else { break }
            guard current.path.hasPrefix(home) || directories.count < 16 else { break }
            current = parent
        }

        return directories
    }
}

struct TaskRunnerSourceScanner {
    let sourceRoot: URL
    let focusedWorkingDirectory: String
    let fileManager: FileManager

    func scan() -> [TaskRunnerAction] {
        var actions: [TaskRunnerAction] = []
        actions += collect(scanPackageScripts)
        actions += collect(scanTaskfile)
        actions += collect(scanVSCodeTasks)
        actions += collect(scanJustfile)
        actions += collect(scanMakefile)
        actions += collect(scanMise)
        return actions
    }

    private func collect(_ scan: () throws -> [TaskRunnerAction]) -> [TaskRunnerAction] {
        (try? scan()) ?? []
    }

    private func scanPackageScripts() throws -> [TaskRunnerAction] {
        let url = sourceRoot.appendingPathComponent("package.json")
        guard fileManager.fileExists(atPath: url.path) else { return [] }

        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any]
        else {
            return []
        }

        let runner = packageRunner(from: object, sourceRoot: sourceRoot)
        return scripts.compactMap { key, value in
            guard value is String else { return nil }
            let command = "\(runner) run \(TaskRunnerShellQuoter.quote(key))"
            return action(
                title: key,
                description: nil,
                sourceKind: .packageScript,
                sourcePath: url,
                executionCommand: command,
                commandPreview: command,
                environment: [:],
                disabledReason: nil
            )
        }
        .sorted { $0.title < $1.title }
    }

    private func packageRunner(from object: [String: Any], sourceRoot: URL) -> String {
        if let packageManager = object["packageManager"] as? String {
            let name = packageManager.split(separator: "@").first.map(String.init) ?? packageManager
            if ["pnpm", "yarn", "bun", "npm"].contains(name) {
                return name
            }
        }

        let lockfiles: [(String, String)] = [
            ("pnpm-lock.yaml", "pnpm"),
            ("yarn.lock", "yarn"),
            ("bun.lockb", "bun"),
            ("bun.lock", "bun"),
            ("package-lock.json", "npm"),
        ]
        return lockfiles.first {
            fileManager.fileExists(atPath: sourceRoot.appendingPathComponent($0.0).path)
        }?.1 ?? "npm"
    }

    private func scanTaskfile() throws -> [TaskRunnerAction] {
        let candidates = ["Taskfile.yml", "Taskfile.yaml"]
            .map { sourceRoot.appendingPathComponent($0) }
        guard let url = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return []
        }

        let root = try parseTaskfile(url)
        var actions = taskfileActions(
            tasks: root.tasks,
            titlePrefix: nil,
            sourcePath: url,
            commandPrefix: nil
        )

        for include in root.includes {
            guard let includeURL = resolvedTaskfileInclude(include.path, relativeTo: sourceRoot),
                  let includeRoot = try? parseTaskfile(includeURL)
            else {
                continue
            }
            actions += taskfileActions(
                tasks: includeRoot.tasks,
                titlePrefix: include.alias,
                sourcePath: includeURL,
                commandPrefix: include.alias
            )
        }

        return actions
    }

    private func taskfileActions(
        tasks: [ParsedTaskfileTask],
        titlePrefix: String?,
        sourcePath: URL,
        commandPrefix: String?
    ) -> [TaskRunnerAction] {
        tasks.compactMap { task in
            guard !task.name.hasPrefix("_") else { return nil }
            let title = [titlePrefix, task.name].compactMap { $0 }.joined(separator: ":")
            let commandTarget = [commandPrefix, task.name].compactMap { $0 }.joined(separator: ":")
            let command = "task \(TaskRunnerShellQuoter.quote(commandTarget))"
            let description = task.description

            return action(
                title: title,
                description: description,
                sourceKind: .taskfile,
                sourcePath: sourcePath,
                executionCommand: command,
                commandPreview: command,
                environment: [:],
                disabledReason: taskfileDisabledReason(task: task)
            )
        }
    }

    private func taskfileDisabledReason(task: ParsedTaskfileTask) -> TaskRunnerDisabledReason? {
        guard !task.requiredVariables.isEmpty
        else {
            return nil
        }
        let names = task.requiredVariables.joined(separator: ", ")
        return .unsupported("Task requires variables: \(names)")
    }

    private func resolvedTaskfileInclude(_ path: String, relativeTo sourceRoot: URL) -> URL? {
        guard !path.contains("{{"),
              !path.hasPrefix("http://"),
              !path.hasPrefix("https://")
        else {
            return nil
        }

        let resolved = URL(fileURLWithPath: path, relativeTo: sourceRoot)
            .standardizedFileURL
        if fileManager.fileExists(atPath: resolved.path) {
            return resolved
        }
        let taskfile = resolved.appendingPathComponent("Taskfile.yml")
        if fileManager.fileExists(atPath: taskfile.path) {
            return taskfile
        }
        let taskfileYAML = resolved.appendingPathComponent("Taskfile.yaml")
        if fileManager.fileExists(atPath: taskfileYAML.path) {
            return taskfileYAML
        }
        return nil
    }

    func action(
        title: String,
        description: String?,
        sourceKind: TaskRunnerSourceKind,
        sourcePath: URL,
        executionCommand: String,
        commandPreview: String,
        environment: [String: String],
        disabledReason: TaskRunnerDisabledReason?
    ) -> TaskRunnerAction {
        let sourcePath = sourcePath.standardizedFileURL.path
        return TaskRunnerAction(
            id: "\(sourceKind.rawValue)|\(sourcePath)|\(title)",
            title: title,
            description: description,
            sourceKind: sourceKind,
            sourcePath: sourcePath,
            sourceRoot: sourceRoot.path,
            workingDirectory: sourceRoot.path,
            executionCommand: executionCommand,
            commandPreview: commandPreview,
            environment: environment,
            disabledReason: disabledReason
        )
    }
}

private func uniquedActions(_ actions: [TaskRunnerAction]) -> [TaskRunnerAction] {
    var nextDuplicateIndexByID: [String: Int] = [:]
    return actions.map { action in
        let duplicateIndex = nextDuplicateIndexByID[action.id] ?? 0
        nextDuplicateIndexByID[action.id] = duplicateIndex + 1
        guard duplicateIndex > 0 else {
            return action
        }
        return action.withID("\(action.id)#\(duplicateIndex + 1)")
    }
}
