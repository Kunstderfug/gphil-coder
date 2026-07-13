import XCTest
@testable import GPhilCoder
@testable import GPhilCoderCore

@MainActor
final class FolderSyncAppKitPromptBoundaryTests: XCTestCase {
    func testDestructivePromptSummarizesPairsItemsAndCombinedBytes() {
        let summary = FolderSyncDestructiveSummary(
            affectedPairCount: 2,
            pairTitles: ["Orchestra", "Stems"],
            deleteCount: 3,
            deleteBytes: 2_048,
            overwriteCount: 2,
            overwriteBytes: 4_096
        )

        let content = FolderSyncAppKitPromptBoundary.destructivePromptContent(summary)
        let details = content.details.joined(separator: "\n")

        XCTAssertEqual(content.message, "Apply destructive folder sync plan?")
        XCTAssertTrue(details.contains("5 destructive items"))
        XCTAssertTrue(details.contains("Orchestra, Stems"))
        XCTAssertTrue(details.contains(Int64(6_144).formattedFileSize))
        XCTAssertTrue(details.contains("3 destination items"))
        XCTAssertTrue(details.contains("2 existing items"))
    }
}
