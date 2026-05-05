import Foundation

struct TmuxCompatArguments: Equatable {
    let valuesByFlag: [String: String]
    let flags: Set<String>
    let positionals: [String]

    static func parse(
        _ arguments: [String],
        valueFlags: Set<String>,
        boolFlags: Set<String>
    ) -> TmuxCompatArguments {
        var valuesByFlag: [String: String] = [:]
        var flags: Set<String> = []
        var positionals: [String] = []
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if valueFlags.contains(argument) {
                if index + 1 < arguments.count {
                    valuesByFlag[argument] = arguments[index + 1]
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
                if let valueFlag = clusterFlags.first(where: valueFlags.contains),
                   argument.hasPrefix(valueFlag) {
                    let valueStart = argument.index(argument.startIndex, offsetBy: valueFlag.count)
                    valuesByFlag[valueFlag] = String(argument[valueStart...])
                    index += 1
                    continue
                }
            }

            positionals.append(argument)
            index += 1
        }

        return TmuxCompatArguments(
            valuesByFlag: valuesByFlag,
            flags: flags,
            positionals: positionals
        )
    }

    func value(_ flag: String) -> String? {
        valuesByFlag[flag]
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
