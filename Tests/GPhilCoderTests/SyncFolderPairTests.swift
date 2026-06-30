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
}
