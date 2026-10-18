import Foundation

struct TmuxCompatArguments: Equatable {
    /// Last value given for each value flag.
    let valuesByFlag: [String: String]
    /// Every value given for each value flag, in order (`-e A=1 -e B=2`).
    var allValuesByFlag: [String: [String]] = [:]
    let flags: Set<String>
    let positionals: [String]

    static func parse(
        _ arguments: [String],
        valueFlags: Set<String>,
        boolFlags: Set<String>
    ) -> TmuxCompatArguments {
        var valuesByFlag: [String: String] = [:]
        var allValuesByFlag: [String: [String]] = [:]
        var flags: Set<String> = []
        var positionals: [String] = []
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                // POSIX end-of-options terminator: consume `--` and treat every
                // remaining argument as a positional verbatim. A tmux
                // `split-window … -- <command>` relies on this so the command
                // (e.g. the `cat` keep-alive placeholder) is not corrupted into
                // the `-- cat` string that crashes the launched shell with
                // `zsh: no such option: cat`. See dedene/zentty#58.
                positionals.append(contentsOf: arguments[(index + 1)...])
                break
            }
            if valueFlags.contains(argument) {
                if index + 1 < arguments.count {
                    valuesByFlag[argument] = arguments[index + 1]
                    allValuesByFlag[argument, default: []].append(arguments[index + 1])
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            if boolFlags.contains(argument) {
                flags.insert(argument)
                index += 1
                continue
            }

            if argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 2 {
                let clusterFlags = argument.dropFirst().map { "-\($0)" }
                if clusterFlags.allSatisfy(boolFlags.contains) {
                    flags.formUnion(clusterFlags)
                    index += 1
                    continue
                }
                // getopt-style cluster: leading boolean flags, then at most one
                // value flag whose value is the rest of the word (`-l70%`) or,
                // when it ends the word, the next argument (`-at target`).
                if let valueFlagOffset = clusterFlags.firstIndex(where: valueFlags.contains),
                   clusterFlags[..<valueFlagOffset].allSatisfy(boolFlags.contains) {
                    let valueFlag = clusterFlags[valueFlagOffset]
                    let valueStart = argument.index(argument.startIndex, offsetBy: valueFlagOffset + 2)
                    let inlineValue = String(argument[valueStart...])
                    let value: String?
                    if !inlineValue.isEmpty {
                        value = inlineValue
                        index += 1
                    } else if index + 1 < arguments.count {
                        value = arguments[index + 1]
                        index += 2
                    } else {
                        value = nil
                        index += 1
                    }
                    flags.formUnion(clusterFlags[..<valueFlagOffset])
                    if let value {
                        valuesByFlag[valueFlag] = value
                        allValuesByFlag[valueFlag, default: []].append(value)
                    }
                    continue
                }
            }

            // Like getopt, option parsing ends at the first word that is not
            // an option: `split-window -t %1 sh -c 'x'` runs `sh -c 'x'`, and
            // `send-keys ls -la Enter` types `ls -la`. An unknown option
            // before that point is kept as a positional and parsing goes on.
            guard argument.hasPrefix("-"), argument.count > 1 else {
                positionals.append(contentsOf: arguments[index...])
                break
            }
            positionals.append(argument)
            index += 1
        }

        return TmuxCompatArguments(
            valuesByFlag: valuesByFlag,
            allValuesByFlag: allValuesByFlag,
            flags: flags,
            positionals: positionals
        )
    }

    func value(_ flag: String) -> String? {
        valuesByFlag[flag]
    }

    func values(_ flag: String) -> [String] {
        allValuesByFlag[flag] ?? []
    }

    func hasFlag(_ flag: String) -> Bool {
        flags.contains(flag)
    }

    var formatTemplate: String? {
        value("-F")
    }

    var displayTemplate: String? {
        if !positionals.isEmpty {
            return positionals.joined(separator: " ")
        }
        return formatTemplate
    }
}
