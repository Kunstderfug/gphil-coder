import Foundation
import GPhilCoderCore

struct RestoreUnresolvedExportRequest: Sendable {
    let items: [RestoreUnresolvedFile]
    let isPartialSearchSnapshot: Bool
    let deletedFolderPath: String?
    let backupRootPath: String?
    let restoreRootPath: String?
    let matchMode: String
    let hashMode: String
    let progressPhase: String?
    let progressDetail: String?
    let deletedCount: Int
    let restoredCount: Int
}

enum RestoreUnresolvedExporter {
    static func defaultFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "GPhil MediaFlow Unresolved \(formatter.string(from: date)).json"
    }

    @discardableResult
    static func export(
        _ request: RestoreUnresolvedExportRequest,
        to url: URL,
        exportedAt: Date = Date()
    ) throws -> URL {
        let exportURL = normalizedJSONFileURL(url)
        let document = RestoreUnresolvedExportDocument(
            version: 1,
            exportedAt: exportedAt,
            isPartialSearchSnapshot: request.isPartialSearchSnapshot,
            deletedFolderPath: request.deletedFolderPath,
            backupRootPath: request.backupRootPath,
            restoreRootPath: request.restoreRootPath,
            matchMode: request.matchMode,
            hashMode: request.hashMode,
            progressPhase: request.progressPhase,
            progressDetail: request.progressDetail,
            deletedCount: request.deletedCount,
            restoredCount: request.restoredCount,
            unresolvedListCount: request.items.count,
            files: request.items
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: exportURL, options: .atomic)
        return exportURL
    }

    static func normalizedJSONFileURL(_ url: URL) -> URL {
        url.pathExtension.isEmpty ? url.appendingPathExtension("json") : url
    }
}

private struct RestoreUnresolvedExportDocument: Encodable {
    let version: Int
    let exportedAt: Date
    let isPartialSearchSnapshot: Bool
    let deletedFolderPath: String?
    let backupRootPath: String?
    let restoreRootPath: String?
    let matchMode: String
    let hashMode: String
    let progressPhase: String?
    let progressDetail: String?
    let deletedCount: Int
    let restoredCount: Int
    let unresolvedListCount: Int
    let files: [RestoreUnresolvedFile]
}
