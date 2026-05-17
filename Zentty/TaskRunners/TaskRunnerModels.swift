import Foundation

enum TaskRunnerSourceKind: String, Equatable, Sendable {
    case packageScript
    case taskfile
    case vscodeTask
    case justfile
    case makefile
    case mise

    var displayName: String {
        switch self {
        case .packageScript:
            "package.json"
        case .taskfile:
            "Taskfile"
        case .vscodeTask:
            "VS Code"
        case .justfile:
            "just"
        case .makefile:
            "make"
        case .mise:
            "mise"
        }
    }
}

enum TaskRunnerDisabledReason: Equatable, Sendable {
    case unsupported(String)

    var displayText: String {
        switch self {
        case .unsupported(let reason):
            reason
        }
    }
}

struct TaskRunnerAction: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let description: String?
    let sourceKind: TaskRunnerSourceKind
    let sourcePath: String
    let sourceRoot: String
    let workingDirectory: String
    let executionCommand: String
    let commandPreview: String
    let environment: [String: String]
    let disabledReason: TaskRunnerDisabledReason?

    var isEnabled: Bool {
        disabledReason == nil
    }

    var subtitle: String {
        let sourceName = URL(fileURLWithPath: sourcePath).lastPathComponent
        let source = sourceName == sourceKind.displayName
            ? sourceName
            : "\(sourceKind.displayName) • \(sourceName)"
        let base = "\(source) • \(commandPreview)"
        guard let disabledReason else {
            return base
        }
        return "\(base) • \(disabledReason.displayText)"
    }

    func withID(_ id: String) -> TaskRunnerAction {
        TaskRunnerAction(
            id: id,
            title: title,
            description: description,
            sourceKind: sourceKind,
            sourcePath: sourcePath,
            sourceRoot: sourceRoot,
            workingDirectory: workingDirectory,
            executionCommand: executionCommand,
            commandPreview: commandPreview,
            environment: environment,
            disabledReason: disabledReason
        )
    }
}

enum TaskRunnerShellQuoter {
    static func quote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
