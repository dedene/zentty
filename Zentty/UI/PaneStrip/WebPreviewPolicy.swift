import Foundation

enum WebPreviewPolicy {
    struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host?.lowercased(), !host.isEmpty else { return nil }
            self.scheme = scheme
            self.host = host
            port = url.port ?? (scheme == "https" ? 443 : 80)
        }
    }

    static func resourceURL(_ value: String) -> URL? {
        if value.hasPrefix("/") { return URL(fileURLWithPath: value).standardizedFileURL }
        guard let url = URL(string: value), url.user == nil, url.password == nil else { return nil }
        if url.isFileURL {
            guard url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            return url.standardizedFileURL
        }
        return Origin(url) == nil ? nil : url
    }

    static func isLocalhost(_ url: URL) -> Bool {
        guard Origin(url) != nil, let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
                && UInt16(part).map { $0 <= 255 } == true
        }
    }

    static func allowsJavaScript(at url: URL, settings: AppConfig.WebPreview) -> Bool {
        settings.javaScriptEnabled || (settings.localhostJavaScriptEnabled && isLocalhost(url))
    }

    static func allowsNavigation(to url: URL, source: URL, mainFrame: Bool,
                                 settings: AppConfig.WebPreview) -> Bool {
        if url.absoluteString == "about:blank" || url.absoluteString.hasPrefix("about:blank#") { return true }
        guard url.user == nil, url.password == nil else { return false }
        if url.isFileURL {
            guard source.isFileURL else { return false }
            let root = source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.starts(with: root)
        }
        guard let destination = Origin(url) else { return false }
        if !mainFrame { return true }
        return settings.browsingEnabled || Origin(source) == destination
    }

    static func permissionsChanged(_ old: AppConfig.WebPreview, _ new: AppConfig.WebPreview) -> Bool {
        old.javaScriptEnabled != new.javaScriptEnabled
            || old.localhostJavaScriptEnabled != new.localhostJavaScriptEnabled
            || old.persistentStorageEnabled != new.persistentStorageEnabled
            || old.browsingEnabled != new.browsingEnabled
    }
}
