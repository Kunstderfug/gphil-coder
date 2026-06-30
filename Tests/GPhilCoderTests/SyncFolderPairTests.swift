import Foundation
import XCTest
@testable import GPhilCoder

final class SyncFolderPairTests: XCTestCase {
    func testOriginSubfolderLayoutDoesNotDuplicateMatchingDestinationLeaf() {
        let pair = SyncFolderPair(
            originPath: "/Volumes/Origin/folder1/parts",
            destinationPath: "/Volumes/Backup/folder2/parts"
        )

        XCTAssertEqual(
            pair.effectiveDestinationURL(layout: .originSubfolder).path,
            "/Volumes/Backup/folder2/parts"
        )
    }

    func testOriginSubfolderLayoutAppendsOriginLeafForSharedDestinationRoot() {
        let pair = SyncFolderPair(
            originPath: "/Volumes/Origin/folder1/parts",
            destinationPath: "/Volumes/Backup/folder2"
        )

        XCTAssertEqual(
            pair.effectiveDestinationURL(layout: .originSubfolder).path,
            "/Volumes/Backup/folder2/parts"
        )
    }

    func testOriginSubfolderLayoutUsesParentWhenSiblingOriginsHaveSameLeaf() {
        let first = SyncFolderPair(
            originPath: "/Volumes/Origin/folder1/parts",
            destinationPath: "/Volumes/Backup/folder3"
        )
        let second = SyncFolderPair(
            originPath: "/Volumes/Origin/folder2/parts",
            destinationPath: "/Volumes/Backup/folder3"
        )
        let pairs = [first, second]

        XCTAssertEqual(
            first.effectiveDestinationURL(layout: .originSubfolder, allPairs: pairs).path,
            "/Volumes/Backup/folder3/folder1/parts"
        )
        XCTAssertEqual(
            second.effectiveDestinationURL(layout: .originSubfolder, allPairs: pairs).path,
            "/Volumes/Backup/folder3/folder2/parts"
        )
    }

    func testOriginSubfolderLayoutUsesShortestUniqueOriginSuffix() {
        let first = SyncFolderPair(
            originPath: "/Volumes/Origin/projectA/folder/parts",
            destinationPath: "/Volumes/Backup/folder3"
        )
        let second = SyncFolderPair(
            originPath: "/Volumes/Origin/projectB/folder/parts",
            destinationPath: "/Volumes/Backup/folder3"
        )
        let pairs = [first, second]

        XCTAssertEqual(
            first.effectiveDestinationURL(layout: .originSubfolder, allPairs: pairs).path,
            "/Volumes/Backup/folder3/projectA/folder/parts"
        )
        XCTAssertEqual(
            second.effectiveDestinationURL(layout: .originSubfolder, allPairs: pairs).path,
            "/Volumes/Backup/folder3/projectB/folder/parts"
        )
    }

    func testPersistenceDecodesPairsSavedWithISO8601Dates() throws {
        let addedAt = ISO8601DateFormatter().date(from: "2026-06-30T12:34:56Z")!
        let pair = SyncFolderPair(
            id: UUID(uuidString: "2D83B474-A611-4CF7-B050-B0F0E59C4A5A")!,
            originPath: "/Volumes/Origin/parts",
            destinationPath: "/Volumes/Backup",
            addedAt: addedAt
        )

        let data = try SyncFolderPairPersistence.encode([pair])
        let decoded = try SyncFolderPairPersistence.decode(data)

        XCTAssertEqual(decoded, [pair])
    }
}
