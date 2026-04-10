#!/usr/bin/env swift

import Foundation

struct ThirdPartyLicenseEntry: Codable, Equatable {
    let id: String
    let displayName: String
    let version: String
    let licenseName: String
    let spdxID: String?
    let sourceURLString: String
    let homepageURLString: String?
    let fullText: String
}

private struct ThirdPartyLicenseCatalog: Codable, Equatable {
    let entries: [ThirdPartyLicenseEntry]
}

private struct PackageResolved: Codable {
    let pins: [PackagePin]
}

private struct PackagePin: Codable {
    let identity: String
    let location: String
    let state: PackageState
}

private struct PackageState: Codable {
    let revision: String
    let version: String
}

private struct GhosttyLock {
    let repo: String
    let revision: String
    let buildTarget: String
}

private struct OverrideFile: Codable {
    let entries: [OverrideEntry]
}

private struct OverrideEntry: Codable {
    let id: String
    let displayName: String?
    let repositoryURL: String?
    let homepageURLString: String?
    let versionOverride: String?
    let sourceURLString: String?
    let licenseNameOverride: String?
    let spdxIDOverride: String?
    let licenseTextOverride: String?
}

private struct GitHubLicenseResponse: Decodable {
    struct License: Decodable {
        let key: String?
        let name: String?
        let spdx_id: String?
    }

    let license: License?
    let html_url: String?
    let content: String?
    let download_url: String?
}

private struct ResolvedPackage {
    let id: String
    let displayName: String
    let version: String
    let reference: String
    let repositoryURL: String
    let homepageURLString: String?
    let sourceURLString: String?
    let licenseNameOverride: String?
    let spdxIDOverride: String?
    let licenseTextOverride: String?
}

enum ThirdPartyLicenseGenerator {
    static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let checkOnly = arguments.contains("--check")

        let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
        let scriptsDirectory = scriptURL.deletingLastPathComponent()
        let repoRoot = scriptsDirectory.deletingLastPathComponent()

        let packageResolvedURL = repoRoot
            .appendingPathComponent("Zentty.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let ghosttyLockURL = repoRoot.appendingPathComponent("scripts/ghosttykit.lock")
        let overridesURL = repoRoot.appendingPathComponent("scripts/licenses/overrides.json")
        let outputURL = repoRoot.appendingPathComponent("ZenttyResources/ThirdPartyLicenses.json")

        let packageResolved = try loadPackageResolved(from: packageResolvedURL)
        let ghosttyLock = try loadGhosttyLock(from: ghosttyLockURL)
        let overrides = try loadOverrides(from: overridesURL)

        let packages = try buildPackages(
            from: packageResolved,
            ghosttyLock: ghosttyLock,
            overrides: overrides
        )

        let entries = try await buildEntries(from: packages)
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ThirdPartyLicenseCatalog(entries: entries))

        if checkOnly {
            let existingData = try Data(contentsOf: outputURL)
            if existingData != data {
                fputs("ThirdPartyLicenses.json is out of date. Regenerate it with:\n", stderr)
                fputs("  swift scripts/generate_third_party_licenses.swift\n", stderr)
                exit(1)
            }
            return
        }

        try data.write(to: outputURL, options: [.atomic])
        print("Wrote \(outputURL.path)")
    }

    private static func loadPackageResolved(from url: URL) throws -> PackageResolved {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PackageResolved.self, from: data)
    }

    private static func loadGhosttyLock(from url: URL) throws -> GhosttyLock {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var values: [String: String] = [:]

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equalsIndex = line.firstIndex(of: "=") else {
                continue
            }

            let key = String(line[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
            values[key] = value
        }

        guard let repo = values["repo"], let revision = values["revision"], let buildTarget = values["build_target"] else {
            throw GeneratorError.invalidGhosttyLock
        }

        return GhosttyLock(repo: repo, revision: revision, buildTarget: buildTarget)
    }

    private static func loadOverrides(from url: URL) throws -> [OverrideEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(OverrideFile.self, from: data).entries
    }

    private static func buildPackages(
        from packageResolved: PackageResolved,
        ghosttyLock: GhosttyLock,
        overrides: [OverrideEntry]
    ) throws -> [ResolvedPackage] {
        let overridesByID = Dictionary(uniqueKeysWithValues: overrides.map { ($0.id, $0) })
        var packages: [ResolvedPackage] = []

        for pin in packageResolved.pins {
            let override = overridesByID[pin.identity]
            packages.append(
                ResolvedPackage(
                    id: pin.identity,
                    displayName: override?.displayName ?? prettyDisplayName(for: pin.identity),
                    version: override?.versionOverride ?? pin.state.version,
                    reference: pin.state.revision,
                    repositoryURL: override?.repositoryURL ?? pin.location,
                    homepageURLString: override?.homepageURLString,
                    sourceURLString: override?.sourceURLString,
                    licenseNameOverride: override?.licenseNameOverride,
                    spdxIDOverride: override?.spdxIDOverride,
                    licenseTextOverride: override?.licenseTextOverride
                )
            )
        }

        if let ghosttyOverride = overridesByID["ghostty"] {
            packages.append(
                ResolvedPackage(
                    id: "ghostty",
                    displayName: ghosttyOverride.displayName ?? "Ghostty",
                    version: ghosttyOverride.versionOverride ?? ghosttyLock.revision,
                    reference: ghosttyLock.revision,
                    repositoryURL: ghosttyOverride.repositoryURL ?? ghosttyLock.repo.replacingOccurrences(of: ".git", with: ""),
                    homepageURLString: ghosttyOverride.homepageURLString,
                    sourceURLString: ghosttyOverride.sourceURLString,
                    licenseNameOverride: ghosttyOverride.licenseNameOverride,
                    spdxIDOverride: ghosttyOverride.spdxIDOverride,
                    licenseTextOverride: ghosttyOverride.licenseTextOverride
                )
            )
        }

        return packages
    }

    private static func buildEntries(from packages: [ResolvedPackage]) async throws -> [ThirdPartyLicenseEntry] {
        try await withThrowingTaskGroup(of: ThirdPartyLicenseEntry.self) { group in
            for package in packages {
                group.addTask {
                    try await buildEntry(from: package)
                }
            }

            var entries: [ThirdPartyLicenseEntry] = []
            for try await entry in group {
                entries.append(entry)
            }
            return entries
        }
    }

    private static func buildEntry(from package: ResolvedPackage) async throws -> ThirdPartyLicenseEntry {
        if let licenseTextOverride = package.licenseTextOverride {
            return ThirdPartyLicenseEntry(
                id: package.id,
                displayName: package.displayName,
                version: package.version,
                licenseName: package.licenseNameOverride ?? "Custom",
                spdxID: package.spdxIDOverride,
                sourceURLString: package.sourceURLString ?? package.repositoryURL,
                homepageURLString: package.homepageURLString ?? package.repositoryURL,
                fullText: licenseTextOverride
            )
        }

        let apiURL = try githubLicenseAPIURL(for: package.repositoryURL, reference: package.reference)
        let response = try await fetchGitHubLicenseResponse(from: apiURL)
        let licenseName = package.licenseNameOverride ?? response.license?.name ?? "Unknown"
        let spdxID = package.spdxIDOverride ?? normalizedSPDXID(from: response.license?.spdx_id)
        let sourceURLString = package.sourceURLString ?? response.html_url ?? package.repositoryURL
        let fullText = try await decodeLicenseText(from: response)

        return ThirdPartyLicenseEntry(
            id: package.id,
            displayName: package.displayName,
            version: package.version,
            licenseName: licenseName,
            spdxID: spdxID,
            sourceURLString: sourceURLString,
            homepageURLString: package.homepageURLString ?? package.repositoryURL,
            fullText: fullText
        )
    }

    private static func decodeLicenseText(from response: GitHubLicenseResponse) async throws -> String {
        let encodedContent = response.content?.replacingOccurrences(
            of: "\\s+",
            with: "",
            options: .regularExpression
        )

        if let encodedContent, let data = Data(base64Encoded: encodedContent), let text = String(data: data, encoding: .utf8) {
            return text
        }

        if let downloadURLString = response.download_url {
            guard let downloadURL = URL(string: downloadURLString) else {
                throw GeneratorError.invalidDownloadURL(downloadURLString)
            }
            let (data, _) = try await URLSession.shared.data(from: downloadURL)
            if let text = String(data: data, encoding: .utf8) {
                return text
            }
        }

        throw GeneratorError.unableToDecodeLicenseText
    }

    private static func fetchGitHubLicenseResponse(from url: URL) async throws -> GitHubLicenseResponse {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Zentty license generator", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            throw GeneratorError.unableToFetchLicense(url: url)
        }

        return try JSONDecoder().decode(GitHubLicenseResponse.self, from: data)
    }

    private static func githubLicenseAPIURL(for repositoryURLString: String, reference: String) throws -> URL {
        let normalizedRepositoryURLString = repositoryURLString
            .replacingOccurrences(of: ".git", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: normalizedRepositoryURLString),
              let repositoryComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GeneratorError.invalidRepositoryURL(repositoryURLString)
        }

        let pathComponents = repositoryComponents.path.split(separator: "/").filter { !$0.isEmpty }
        guard pathComponents.count >= 2 else {
            throw GeneratorError.invalidRepositoryURL(repositoryURLString)
        }

        let owner = pathComponents[pathComponents.count - 2]
        let repo = pathComponents[pathComponents.count - 1]
        guard var components = URLComponents(string: "https://api.github.com/repos/\(owner)/\(repo)/license") else {
            throw GeneratorError.invalidRepositoryURL(repositoryURLString)
        }
        components.queryItems = [
            URLQueryItem(name: "ref", value: reference),
        ]
        guard let apiURL = components.url else {
            throw GeneratorError.invalidRepositoryURL(repositoryURLString)
        }
        return apiURL
    }

    private static func normalizedSPDXID(from value: String?) -> String? {
        guard let value, value != "NOASSERTION", !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func prettyDisplayName(for identity: String) -> String {
        identity
            .split(separator: "-")
            .map { component in
                let lowercased = component.lowercased()
                return String(lowercased.prefix(1)).uppercased() + lowercased.dropFirst()
            }
            .joined(separator: " ")
    }
}

private enum GeneratorError: Error, CustomStringConvertible {
    case invalidGhosttyLock
    case invalidRepositoryURL(String)
    case invalidDownloadURL(String)
    case unableToDecodeLicenseText
    case unableToFetchLicense(url: URL)

    var description: String {
        switch self {
        case .invalidGhosttyLock:
            return "Ghostty lock file is missing required keys"
        case .invalidRepositoryURL(let value):
            return "Repository URL is invalid or unsupported: \(value)"
        case .invalidDownloadURL(let value):
            return "License download URL is invalid: \(value)"
        case .unableToDecodeLicenseText:
            return "Unable to decode license text from GitHub response"
        case .unableToFetchLicense(let url):
            return "Unable to fetch GitHub license metadata from \(url.absoluteString)"
        }
    }
}

do {
    try await ThirdPartyLicenseGenerator.run()
} catch {
    if let generatorError = error as? GeneratorError {
        fputs(generatorError.description + "\n", stderr)
    } else {
        fputs("Unexpected error: \(error)\n", stderr)
    }
    exit(1)
}
