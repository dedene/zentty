import Foundation

struct ThirdPartyLicenseEntry: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let displayName: String
    let version: String
    let licenseName: String
    let spdxID: String?
    let sourceURLString: String
    let homepageURLString: String?
    let fullText: String

    var sourceURL: URL? {
        URL(string: sourceURLString)
    }

    var homepageURL: URL? {
        guard let homepageURLString else {
            return nil
        }

        return URL(string: homepageURLString)
    }
}

struct ThirdPartyLicenseCatalog: Codable, Equatable, Sendable {
    let entries: [ThirdPartyLicenseEntry]

    init(entries: [ThirdPartyLicenseEntry]) {
        self.entries = entries
    }

    static func load(from bundle: Bundle) throws -> ThirdPartyLicenseCatalog {
        let resourceURL = try findResourceURL(from: bundle)
        let data = try Data(contentsOf: resourceURL)
        let decoder = JSONDecoder()
        let topLevelObject = try JSONSerialization.jsonObject(with: data)

        switch topLevelObject {
        case is [String: Any]:
            return try decoder.decode(ThirdPartyLicenseCatalog.self, from: data)
        case is [Any]:
            let entries = try decoder.decode([ThirdPartyLicenseEntry].self, from: data)
            return ThirdPartyLicenseCatalog(entries: entries)
        default:
            throw CocoaError(.coderReadCorrupt)
        }
    }

    private static func findResourceURL(from bundle: Bundle) throws -> URL {
        let candidateBundles = [bundle, Bundle(for: BundleLocator.self)] + Bundle.allBundles + Bundle.allFrameworks

        for candidate in candidateBundles {
            if let url = candidate.url(forResource: "ThirdPartyLicenses", withExtension: "json") {
                return url
            }
        }

        let fileManager = FileManager.default
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileSystemCandidates = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath),
            sourceRoot,
        ].map {
            $0.appendingPathComponent("ZenttyResources/ThirdPartyLicenses.json")
        }

        for candidate in fileSystemCandidates where fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        throw CocoaError(.fileNoSuchFile)
    }
}

private final class BundleLocator {}
