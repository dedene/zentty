enum ShellEscaping {
    private static let shellSensitiveCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    static func escapePath(_ path: String) -> String {
        var result = path
        for character in shellSensitiveCharacters {
            result = result.replacingOccurrences(
                of: String(character),
                with: "\\\(character)"
            )
        }
        return result
    }
}
