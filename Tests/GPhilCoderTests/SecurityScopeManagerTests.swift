import Foundation
import XCTest
@testable import GPhilCoder

@MainActor
final class SecurityScopeManagerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - uniqueURLs

    func testUniqueURLsRemovesDuplicatesByStandardizedPath() {
        let a = URL(fileURLWithPath: "/tmp/foo.flac")
        let aDuplicate = URL(fileURLWithPath: "/tmp/./foo.flac")
        let b = URL(fileURLWithPath: "/tmp/bar.flac")

        let result = SecurityScopeManager.uniqueURLs([a, aDuplicate, b])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.path), ["/tmp/foo.flac", "/tmp/bar.flac"])
    }

    func testUniqueURLsPreservesOrder() {
        let urls = [
            URL(fileURLWithPath: "/tmp/c.flac"),
            URL(fileURLWithPath: "/tmp/a.flac"),
            URL(fileURLWithPath: "/tmp/b.flac")
        ]
        let result = SecurityScopeManager.uniqueURLs(urls)
        XCTAssertEqual(result.map(\.lastPathComponent), ["c.flac", "a.flac", "b.flac"])
    }

    // MARK: - sameFileURL

    func testSameFileURLTrueForEqualPaths() {
        let a = URL(fileURLWithPath: "/tmp/song.flac")
        XCTAssertTrue(SecurityScopeManager.sameFileURL(a, a))
    }

    func testSameFileURLFalseForDifferentPaths() {
        let a = URL(fileURLWithPath: "/tmp/song.flac")
        let b = URL(fileURLWithPath: "/tmp/other.flac")
        XCTAssertFalse(SecurityScopeManager.sameFileURL(a, b))
    }

    // MARK: - containsFileURL

    func testContainsFileURLTrueForDescendant() {
        let root = URL(fileURLWithPath: "/Volumes/DRIVE/Project", isDirectory: true)
        let file = URL(fileURLWithPath: "/Volumes/DRIVE/Project/Sub/song.flac")
        XCTAssertTrue(SecurityScopeManager.containsFileURL(file, in: root))
    }

    func testContainsFileURLTrueForExactRoot() {
        let root = URL(fileURLWithPath: "/Volumes/DRIVE/Project", isDirectory: true)
        XCTAssertTrue(SecurityScopeManager.containsFileURL(root, in: root))
    }

    func testContainsFileURLFalseForSibling() {
        let root = URL(fileURLWithPath: "/Volumes/DRIVE/Project", isDirectory: true)
        let sibling = URL(fileURLWithPath: "/Volumes/DRIVE/OtherProject/song.flac")
        XCTAssertFalse(SecurityScopeManager.containsFileURL(sibling, in: root))
    }

    func testContainsFileURLFalseForPrefixThatIsNotADirectory() {
        // "/Project" must not be treated as containing "/ProjectX" — the
        // trailing-slash check guards against this prefix-matching bug.
        let root = URL(fileURLWithPath: "/Volumes/DRIVE/Project", isDirectory: true)
        let impostor = URL(fileURLWithPath: "/Volumes/DRIVE/ProjectX/song.flac")
        XCTAssertFalse(SecurityScopeManager.containsFileURL(impostor, in: root))
    }

    // MARK: - canWriteTemporaryFile

    func testCanWriteTemporaryFileTrueForWritableDirectory() throws {
        let dir = try makeTemporaryDirectory()
        let manager = SecurityScopeManager()
        XCTAssertTrue(manager.canWriteTemporaryFile(in: dir))
        // The probe file must be cleaned up.
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".gphilcoder-write-test-") })
    }

    func testCanWriteTemporaryFileFalseForNonexistentRoot() {
        let manager = SecurityScopeManager()
        // A path under a volume that does not exist cannot be created.
        let bogus = URL(fileURLWithPath: "/nonexistent-volume-xyz/\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(manager.canWriteTemporaryFile(in: bogus))
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPhilCoderScopeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}
