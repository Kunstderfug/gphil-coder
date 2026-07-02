import Foundation

/// Owns the security-scoped resource grants for the encoding and folder-sync
/// workflows.
///
/// Each grant is a balanced `startAccessingSecurityScopedResource` /
/// `stopAccessingSecurityScopedResource` pair. Keeping the two buckets in one
/// place (instead of duplicated across the view model) makes it obvious that
/// every start has a matching stop, and removes the ~27 duplicated references
/// that previously lived on `EncoderViewModel`.
///
/// All path-comparison helpers (`uniqueURLs`, `sameFileURL`,
/// `normalizedFilePath`, `containsFileURL`, `canWriteTemporaryFile`) live here
/// too: they are pure Foundation logic with no UI dependency.
@MainActor
final class SecurityScopeManager {
    /// Grants held for an active encode run. Released by `stopEncoding()`,
    /// which `runJobs` calls at every completion/exit point.
    private var activeEncodingURLs: [URL] = []
    /// Grants held for an active folder-sync run. Released by `stopSync()`,
    /// which `runFolderSync` calls at every completion/exit point.
    private var activeSyncURLs: [URL] = []

    // MARK: - Encoding scopes

    /// Starts accessing security scope for each URL not already held. Returns
    /// the URLs that were actually granted (others are silently skipped, as in
    /// the original implementation).
    @discardableResult
    func startEncoding(_ urls: [URL]) -> [URL] {
        start(urls, into: &activeEncodingURLs)
    }

    /// Releases every encoding grant acquired since the last stop.
    func stopEncoding() {
        for url in activeEncodingURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeEncodingURLs.removeAll()
    }

    // MARK: - Folder-sync scopes

    /// Starts accessing security scope for each URL not already held.
    @discardableResult
    func startSync(_ urls: [URL]) -> [URL] {
        start(urls, into: &activeSyncURLs)
    }

    /// Releases every folder-sync grant acquired since the last stop.
    func stopSync() {
        for url in activeSyncURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeSyncURLs.removeAll()
    }

    // MARK: - Write probe

    /// Probes whether `directory` is writable by creating and removing an empty
    /// temp file. Used by the encoding preflight to detect sandbox denials
    /// before launching ffmpeg.
    func canWriteTemporaryFile(in directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let probeURL = directory.appendingPathComponent(
                ".gphilcoder-write-test-\(UUID().uuidString)",
                isDirectory: false
            )
            try Data().write(to: probeURL, options: .withoutOverwriting)
            try? FileManager.default.removeItem(at: probeURL)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Path helpers (pure)

    /// De-duplicates a URL list by standardized path, preserving order.
    static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []

        for url in urls {
            let standardized = url.standardizedFileURL
            let key = standardized.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(standardized)
        }

        return result
    }

    /// Whether two URLs refer to the same file by standardized path.
    static func sameFileURL(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    /// Standardized, symlink-resolved path for security-scope containment checks.
    static func normalizedFilePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Whether `url` is `root` itself or a descendant of `root`.
    static func containsFileURL(_ url: URL, in root: URL) -> Bool {
        let path = normalizedFilePath(url)
        let rootPath = normalizedFilePath(root)
        return path == rootPath || path.hasPrefix("\(rootPath)/")
    }

    // MARK: - Private

    @discardableResult
    private func start(_ urls: [URL], into bucket: inout [URL]) -> [URL] {
        var granted: [URL] = []
        for url in Self.uniqueURLs(urls) where !bucket.contains(where: { Self.sameFileURL($0, url) }) {
            if url.startAccessingSecurityScopedResource() {
                bucket.append(url)
                granted.append(url)
            }
        }
        return granted
    }
}
