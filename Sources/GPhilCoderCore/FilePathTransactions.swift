import Foundation

// File-path transaction helpers used by the App's media-rename and copy flows.
// Pure Foundation logic, extracted to Core so the collision-disambiguation and
// case-only-rename paths can be unit-tested.

/// Resolves a non-colliding destination URL inside `folder`, appending
/// " 2", " 3", ... to `preferredName` until a free name is found. Falls back
/// to a `UUID-<name>` form only if the first 10 000 candidates are taken.
public func availableDestinationURL(
    in folder: URL,
    preferredName: String
) -> URL {
    let fileManager = FileManager.default
    let preferredURL = folder.appendingPathComponent(preferredName, isDirectory: false)
    guard fileManager.fileExists(atPath: preferredURL.path) else { return preferredURL }

    let baseName = (preferredName as NSString).deletingPathExtension
    let fileExtension = (preferredName as NSString).pathExtension

    for index in 2...10_000 {
        let candidateName =
            fileExtension.isEmpty
            ? "\(baseName) \(index)"
            : "\(baseName) \(index).\(fileExtension)"
        let candidateURL = folder.appendingPathComponent(candidateName, isDirectory: false)
        if !fileManager.fileExists(atPath: candidateURL.path) {
            return candidateURL
        }
    }

    return folder.appendingPathComponent(UUID().uuidString + "-" + preferredName)
}

/// Renames `sourceURL` to `targetURL`. Handles case-only renames safely on a
/// case-preserving but case-insensitive filesystem (APFS default): the source
/// and target paths compare equal case-insensitively but differ byte-for-byte,
/// so a direct `moveItem` would no-op. The rename goes through a unique temp
/// file, rolling back to the source on failure. Throws `fileWriteFileExists`
/// if the target already exists (non-case-only case).
public func moveRenameFile(from sourceURL: URL, to targetURL: URL) throws {
    let fileManager = FileManager.default
    let sourcePath = sourceURL.standardizedFileURL.path
    let targetPath = targetURL.standardizedFileURL.path
    let sourceKey = sourcePath.lowercased()
    let targetKey = targetPath.lowercased()

    if sourceKey == targetKey && sourcePath != targetPath {
        let temporaryURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent(".gphilcoder-rename-\(UUID().uuidString).tmp")
        try fileManager.moveItem(at: sourceURL, to: temporaryURL)
        do {
            try fileManager.moveItem(at: temporaryURL, to: targetURL)
        } catch {
            try? fileManager.moveItem(at: temporaryURL, to: sourceURL)
            throw error
        }
        return
    }

    guard !fileManager.fileExists(atPath: targetPath) else {
        throw CocoaError(.fileWriteFileExists)
    }

    try fileManager.moveItem(at: sourceURL, to: targetURL)
}

/// Builds the output filename for a source whose extension matches the target
/// format's extension. When the source and target extensions are the same
/// (e.g. FLAC → FLAC), `-encoded` is inserted to avoid clobbering the source:
/// `Song.flac` → `Song-encoded.flac`. Otherwise the source base name is kept
/// and only the extension changes: `Song.wav` → `Song.flac`.
public func encodedOutputFileName(
    sourceExtension: String,
    baseName: String,
    formatExtension: String
) -> String {
    let outputBaseName = sourceExtension.lowercased() == formatExtension
        ? "\(baseName)-encoded"
        : baseName
    return outputBaseName + "." + formatExtension
}
