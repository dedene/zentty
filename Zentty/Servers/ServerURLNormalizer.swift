import Foundation

struct ServerURLCandidate: Equatable, Sendable {
    let url: URL
    let origin: String
    let display: String
    let port: Int
}

enum ServerURLNormalizer {
    enum Error: Swift.Error, Equatable {
        case emptyInput
        case invalidURL(String)
        case missingHost
        case missingPort
        case invalidPort(String)
        case unsupportedScheme(String)
        case unsupportedHost(String)
    }

    static func normalize(_ rawValue: String) throws -> ServerURLCandidate {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw Error.emptyInput
        }

        let candidate = try normalizedURLString(from: trimmed)
        guard var components = URLComponents(string: candidate) else {
            throw Error.invalidURL(rawValue)
        }

        let scheme = components.scheme?.lowercased() ?? "http"
        guard scheme == "http" || scheme == "https" else {
            throw Error.unsupportedScheme(scheme)
        }
        components.scheme = scheme

        guard let rawHost = components.host, !rawHost.isEmpty else {
            throw Error.missingHost
        }

        let host = normalizedHost(rawHost)
        guard isSupportedHost(host) else {
            throw Error.unsupportedHost(rawHost)
        }
        if host.contains(":") {
            components.percentEncodedHost = "[\(host)]"
        } else {
            components.host = host
        }

        guard let port = components.port else {
            throw Error.missingPort
        }
        guard (1...65535).contains(port) else {
            throw Error.invalidPort(String(port))
        }

        if components.path.isEmpty {
            components.path = "/"
        }

        guard let url = components.url else {
            throw Error.invalidURL(rawValue)
        }

        return ServerURLCandidate(
            url: url,
            origin: "\(scheme)://\(originHost(host)):\(port)",
            display: "\(displayHost(host)):\(port)",
            port: port
        )
    }

    private static func normalizedURLString(from rawValue: String) throws -> String {
        if rawValue.range(of: "^[0-9]+$", options: .regularExpression) != nil {
            guard let port = Int(rawValue), (1...65535).contains(port) else {
                throw Error.invalidPort(rawValue)
            }
            return "http://localhost:\(port)/"
        }

        if rawValue.contains("://") {
            return rawValue
        }

        return "http://\(rawValue)"
    }

    private static func normalizedHost(_ host: String) -> String {
        let lowercased = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        switch lowercased {
        case "0.0.0.0", "::", "::1", "127.0.0.1", "":
            return "localhost"
        default:
            return lowercased
        }
    }

    private static func isSupportedHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") {
            return true
        }

        if isSupportedIPv4(host) {
            return true
        }

        return isSupportedIPv6(host)
    }

    private static func isSupportedIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return false
        }

        let octets = parts.compactMap { part -> Int? in
            guard let value = Int(part), (0...255).contains(value) else {
                return nil
            }
            return value
        }
        guard octets.count == 4 else {
            return false
        }

        if octets[0] == 127 {
            return true
        }
        if octets[0] == 10 {
            return true
        }
        if octets[0] == 172 && (16...31).contains(octets[1]) {
            return true
        }
        if octets[0] == 192 && octets[1] == 168 {
            return true
        }
        if octets[0] == 169 && octets[1] == 254 {
            return true
        }

        return false
    }

    private static func isSupportedIPv6(_ host: String) -> Bool {
        let lowercased = host.lowercased()
        return lowercased.hasPrefix("fc")
            || lowercased.hasPrefix("fd")
            || lowercased.hasPrefix("fe80:")
    }

    private static func originHost(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }

    private static func displayHost(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }
}
