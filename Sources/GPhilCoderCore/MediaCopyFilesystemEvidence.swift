import Foundation

public enum MediaCopyPathKind: String, Hashable, Sendable {
    case missing
    case regularFile
    case directory
    case package
    case other
}

public struct MediaCopyPathEvidence: Hashable, Sendable {
    public let kind: MediaCopyPathKind
    public let fileSizeBytes: Int64
    public let modificationDate: Date?
    public let resourceIdentifier: String?
    public let descendantMetadataSignature: UInt64?

    public static func capture(at url: URL, recursively: Bool = false) -> Self {
        let fileURL = URL(fileURLWithPath: url.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            return Self(
                kind: .missing,
                fileSizeBytes: 0,
                modificationDate: nil,
                resourceIdentifier: nil,
                descendantMetadataSignature: nil
            )
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isPackageKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
        ]
        let values = try? fileURL.resourceValues(forKeys: keys)
        let kind: MediaCopyPathKind
        if values?.isPackage == true {
            kind = .package
        } else if values?.isDirectory == true || isDirectory.boolValue {
            kind = .directory
        } else if values?.isRegularFile == true {
            kind = .regularFile
        } else {
            kind = .other
        }
        return Self(
            kind: kind,
            fileSizeBytes: Int64(values?.fileSize ?? 0),
            modificationDate: values?.contentModificationDate,
            resourceIdentifier: values?.fileResourceIdentifier.map { String(describing: $0) },
            descendantMetadataSignature: recursively && kind == .package
                ? packageMetadataSignature(at: fileURL)
                : nil
        )
    }

    private static func packageMetadataSignature(at root: URL) -> UInt64? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return nil }

        let rootPath = root.standardizedFileURL.path
        var rows: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            let relativePath = String(
                url.standardizedFileURL.path.dropFirst(rootPath.count + 1)
            )
            rows.append(
                "\(relativePath)|\(values?.isDirectory == true ? "d" : "f")|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
            )
        }

        var signature: UInt64 = 14_695_981_039_346_656_037
        for byte in rows.sorted().joined(separator: "\n").utf8 {
            signature ^= UInt64(byte)
            signature &*= 1_099_511_628_211
        }
        return signature
    }
}

public enum MediaCopyPlannedItemKind: String, Hashable, Sendable {
    case file
    case package
}

public struct MediaCopyPlannedDestination: Hashable, Sendable {
    public let path: String
    public let kind: MediaCopyPlannedItemKind

    public init(path: String, kind: MediaCopyPlannedItemKind) {
        self.path = path
        self.kind = kind
    }
}
