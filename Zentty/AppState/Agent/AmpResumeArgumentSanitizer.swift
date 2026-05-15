import Foundation

enum AmpResumeArgumentSanitizer {
    private static let safeValueOptions: Set<String> = [
        "--mode", "-m", "--effort", "--settings-file", "--log-level",
        "--log-file", "--mcp-config", "--visibility",
    ]
    private static let droppedValueOptions: Set<String> = ["--label", "-l"]
    private static let droppedFlags: Set<String> = [
        "--archive", "--stream-json", "--stream-json-input", "--stream-json-thinking",
        "--json", "--output-format",
    ]
    private static let rejectedFlags: Set<String> = [
        "--execute", "--print", "-x", "--help", "-h", "--version", "-V", "--jetbrains",
    ]
    private static let rejectedSubcommands: Set<String> = [
        "login", "logout", "mcp", "permission", "permissions", "review",
        "skill", "skills", "tool", "tools", "update", "up", "usage", "version",
    ]

    static func sanitizedAmpResumeArguments(from arguments: [String]) -> [String]? {
        var remaining = Array(arguments.dropFirstIfExecutableName("amp"))
        if let first = remaining.first, rejectedSubcommands.contains(first) {
            return nil
        }
        if remaining.contains(where: { isRejectedFlag($0) }) {
            return nil
        }
        stripResumePreamble(from: &remaining)

        var sanitized: [String] = []
        var index = 0
        while index < remaining.count {
            let argument = remaining[index]
            if argument.hasPrefix("--") {
                let optionName = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
                if safeValueOptions.contains(optionName) {
                    if argument.contains("=") {
                        sanitized.append(argument)
                    } else if remaining.indices.contains(index + 1), !remaining[index + 1].hasPrefix("-") {
                        sanitized.append(argument)
                        sanitized.append(remaining[index + 1])
                        index += 1
                    }
                } else if droppedValueOptions.contains(optionName) {
                    if !argument.contains("="), remaining.indices.contains(index + 1), !remaining[index + 1].hasPrefix("-") {
                        index += 1
                    }
                } else if droppedFlags.contains(optionName) {
                    if optionName == "--output-format",
                       !argument.contains("="),
                       remaining.indices.contains(index + 1),
                       !remaining[index + 1].hasPrefix("-") {
                        index += 1
                    }
                }
            } else if argument == "-m" {
                if remaining.indices.contains(index + 1), !remaining[index + 1].hasPrefix("-") {
                    sanitized.append(argument)
                    sanitized.append(remaining[index + 1])
                    index += 1
                }
            } else if argument == "-l" {
                if remaining.indices.contains(index + 1), !remaining[index + 1].hasPrefix("-") {
                    index += 1
                }
            } else if argument.hasPrefix("-") {
                if isRejectedFlag(argument) { return nil }
            } else {
                break
            }
            index += 1
        }
        return sanitized
    }

    private static func stripResumePreamble(from arguments: inout [String]) {
        guard arguments.count >= 2 else { return }
        let threadSubcommands: Set<String> = ["threads", "thread", "t"]
        let continueSubcommands: Set<String> = ["continue", "c"]
        guard threadSubcommands.contains(arguments[0]),
              continueSubcommands.contains(arguments[1]) else {
            return
        }
        arguments.removeFirst(2)
        if let first = arguments.first, first.range(of: #"^T-[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil {
            arguments.removeFirst()
        }
    }

    private static func isRejectedFlag(_ argument: String) -> Bool {
        let optionName = argument.hasPrefix("--")
            ? (argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument)
            : argument
        return rejectedFlags.contains(optionName)
    }
}

private extension Array where Element == String {
    func dropFirstIfExecutableName(_ executableName: String) -> ArraySlice<String> {
        guard first == executableName else {
            return self[...]
        }
        return dropFirst()
    }
}
