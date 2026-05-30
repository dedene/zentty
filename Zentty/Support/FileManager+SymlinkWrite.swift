import Foundation

extension FileManager {
    /// Resolves a trailing symlink so an atomic write targets the real file and
    /// preserves the link instead of replacing it with a regular file.
    ///
    /// `.atomic` writes to a temp file and `rename()`s it over the destination, which
    /// replaces a symlink's own inode. Dotfile managers (GNU Stow, chezmoi, yadm,
    /// dotbot) rely on these links; clobbering them silently detaches the live config
    /// from the tracked repo. Writing through to the symlink's real target keeps both
    /// the crash-safety of the atomic write and the link.
    ///
    /// Walks a chain on the final path component only — intermediate directory symlinks
    /// are followed transparently by the OS, so they need no special handling. Returns:
    /// - `url` unchanged when its final component is not a symlink;
    /// - the chain's real target (the first non-symlink), which for a broken link is its
    ///   missing target so the write materializes the file there instead of over the link;
    /// - the original `url` when the chain is cyclic or deeper than the hop limit — a
    ///   degenerate setup with no real target to write through (and one that can't be
    ///   written through anyway), where the original location is the safe fallback.
    func resolvingSymlinkTarget(at url: URL) -> URL {
        var resolved = url
        var visited: Set<String> = []
        for _ in 0..<32 {
            guard let destination = try? destinationOfSymbolicLink(atPath: resolved.path) else {
                return resolved
            }
            guard visited.insert(resolved.path).inserted else {
                break
            }
            resolved = URL(
                fileURLWithPath: destination,
                relativeTo: resolved.deletingLastPathComponent()
            ).absoluteURL
        }
        return url
    }
}
