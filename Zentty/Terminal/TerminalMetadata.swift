struct TerminalMetadata: Equatable {
    var title: String?
    var currentWorkingDirectory: String?
    var processName: String?
    var gitBranch: String?
}

extension TerminalMetadata {
    var hasRenderableContext: Bool {
        [title, currentWorkingDirectory, processName]
            .contains { value in
                guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return false
                }

                return !trimmed.isEmpty
            }
    }
}
