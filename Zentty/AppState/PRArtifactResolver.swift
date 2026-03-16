import Foundation

@MainActor
final class PRArtifactResolver {
    private struct RepositoryKey: Hashable {
        let path: String
        let branch: String
    }

    private enum CacheEntry {
        case resolved(WorkspaceArtifactLink?)
    }

    private var cache: [RepositoryKey: CacheEntry] = [:]
    private var pendingKeys: Set<RepositoryKey> = []
    private var waitingPaneIDs: [RepositoryKey: Set<PaneID>] = [:]

    func refresh(
        for workspaces: [WorkspaceState],
        update: @escaping (PaneID, WorkspaceArtifactLink?) -> Void
    ) {
        for workspace in workspaces {
            for (paneID, status) in workspace.agentStatusByPaneID {
                guard status.artifactLink == nil else {
                    continue
                }
                guard let metadata = workspace.metadataByPaneID[paneID] else {
                    continue
                }
                guard
                    let path = WorkspaceContextFormatter.trimmed(metadata.currentWorkingDirectory),
                    let branch = WorkspaceContextFormatter.trimmed(metadata.gitBranch)
                else {
                    continue
                }

                let key = RepositoryKey(path: path, branch: branch)
                if let cached = cache[key] {
                    switch cached {
                    case .resolved(let artifact):
                        update(paneID, artifact)
                    }
                    continue
                }

                waitingPaneIDs[key, default: []].insert(paneID)
                guard pendingKeys.insert(key).inserted else {
                    continue
                }

                resolve(key: key, update: update)
            }
        }
    }

    private func resolve(
        key: RepositoryKey,
        update: @escaping (PaneID, WorkspaceArtifactLink?) -> Void
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "pr", "view", "--json", "number,url,title"]
        process.currentDirectoryURL = URL(fileURLWithPath: key.path, isDirectory: true)

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        DispatchQueue.global(qos: .utility).async {
            let artifactLink: WorkspaceArtifactLink?
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    artifactLink = Self.parseArtifact(from: outputData)
                } else {
                    artifactLink = nil
                }
            } catch {
                artifactLink = nil
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }

                self.pendingKeys.remove(key)
                self.cache[key] = .resolved(artifactLink)
                let paneIDs = self.waitingPaneIDs.removeValue(forKey: key) ?? []
                paneIDs.forEach { paneID in
                    update(paneID, artifactLink)
                }
            }
        }
    }

    private static func parseArtifact(from data: Data) -> WorkspaceArtifactLink? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let number = object["number"] as? Int,
            let urlString = object["url"] as? String,
            let url = URL(string: urlString)
        else {
            return nil
        }

        return WorkspaceArtifactLink(
            kind: .pullRequest,
            label: "PR #\(number)",
            url: url,
            isExplicit: false
        )
    }
}
