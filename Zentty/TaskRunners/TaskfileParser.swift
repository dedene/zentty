import Foundation

struct ParsedTaskfileTask {
    let name: String
    var description: String?
    var requiredVariables: [String]
}

struct ParsedTaskfile {
    var tasks: [ParsedTaskfileTask]
    var includes: [(alias: String, path: String)]
}

func parseTaskfile(_ url: URL) throws -> ParsedTaskfile {
    let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
    var tasks: [ParsedTaskfileTask] = []
    var includes: [(alias: String, path: String)] = []
    var section: String?
    var currentTaskIndex: Int?
    var currentIncludeAlias: String?
    var inRequires = false
    var readingRequiresVars = false

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
        let indent = line.prefix { $0 == " " }.count
        if indent <= 6 {
            readingRequiresVars = false
        }

        if indent == 0, trimmed.hasSuffix(":") {
            section = String(trimmed.dropLast())
            currentTaskIndex = nil
            currentIncludeAlias = nil
            inRequires = false
            readingRequiresVars = false
            continue
        }

        switch section {
        case "includes":
            if indent == 2, let pair = yamlKeyValue(trimmed) {
                currentIncludeAlias = pair.key
                if !pair.value.isEmpty {
                    if let taskfilePath = yamlInlineMapValue(pair.value, key: "taskfile")
                        ?? yamlInlineMapValue(pair.value, key: "dir") {
                        includes.append((pair.key, taskfilePath))
                    } else {
                        includes.append((pair.key, strippedYAMLScalar(pair.value)))
                    }
                }
                continue
            }

            if indent == 4,
               let currentIncludeAlias,
               let pair = yamlKeyValue(trimmed),
               pair.key == "taskfile" || pair.key == "dir" {
                includes.append((currentIncludeAlias, strippedYAMLScalar(pair.value)))
            }

        case "tasks":
            if indent == 2, trimmed.hasSuffix(":") {
                let name = String(trimmed.dropLast())
                tasks.append(ParsedTaskfileTask(name: name, description: nil, requiredVariables: []))
                currentTaskIndex = tasks.indices.last
                currentIncludeAlias = nil
                inRequires = false
                continue
            }

            guard let currentTaskIndex else { continue }
            if indent == 4, let pair = yamlKeyValue(trimmed) {
                switch pair.key {
                case "desc", "summary":
                    tasks[currentTaskIndex].description = strippedYAMLScalar(pair.value)
                case "requires":
                    inRequires = true
                default:
                    inRequires = false
                    readingRequiresVars = false
                }
                continue
            }

            if indent == 6, inRequires, let pair = yamlKeyValue(trimmed), pair.key == "vars" {
                tasks[currentTaskIndex].requiredVariables = parseYAMLInlineArray(pair.value)
                readingRequiresVars = pair.value.isEmpty
                continue
            }

            if indent == 8, readingRequiresVars, trimmed.hasPrefix("- ") {
                let name = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    tasks[currentTaskIndex].requiredVariables.append(strippedYAMLScalar(name))
                }
            }

        default:
            continue
        }
    }

    return ParsedTaskfile(tasks: tasks, includes: includes)
}

private func yamlKeyValue(_ line: String) -> (key: String, value: String)? {
    guard let colon = line.firstIndex(of: ":") else { return nil }
    let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { return nil }
    return (key, value)
}

private func strippedYAMLScalar(_ value: String) -> String {
    value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
}

private func yamlInlineMapValue(_ value: String, key: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
    return trimmed
        .dropFirst()
        .dropLast()
        .split(separator: ",")
        .compactMap { entry -> String? in
            guard let colon = entry.firstIndex(of: ":") else { return nil }
            let observedKey = String(entry[..<colon]).trimmingCharacters(in: .whitespaces)
            guard observedKey == key else { return nil }
            let rawValue = String(entry[entry.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            return strippedYAMLScalar(rawValue)
        }
        .first
}

private func parseYAMLInlineArray(_ value: String) -> [String] {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
        return trimmed.isEmpty ? [] : [strippedYAMLScalar(trimmed)]
    }
    return trimmed
        .dropFirst()
        .dropLast()
        .split(separator: ",")
        .map { strippedYAMLScalar(String($0).trimmingCharacters(in: .whitespaces)) }
        .filter { !$0.isEmpty }
}
