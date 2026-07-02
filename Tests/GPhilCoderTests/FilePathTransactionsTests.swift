import Foundation
import XCTest
@testable import GPhilCoderCore

final class FilePathTransactionsTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - availableDestinationURL

    func testAvailableDestinationReturnsPreferredWhenFree() throws {
        let folder = try makeTemporaryDirectory()
        let url = availableDestinationURL(in: folder, preferredName: "Song.flac")
        XCTAssertEqual(url.lastPathComponent, "Song.flac")
    }

    func testAvailableDestinationAppendsSuffixOnCollision() throws {
        let folder = try makeTemporaryDirectory()
        try writeFile("Song.flac", in: folder, contents: "x")
        let url = availableDestinationURL(in: folder, preferredName: "Song.flac")
        XCTAssertEqual(url.lastPathComponent, "Song 2.flac")
    }

    func testAvailableDestinationIncrementsThroughMultipleCollisions() throws {
        let folder = try makeTemporaryDirectory()
        try writeFile("Song.flac", in: folder, contents: "a")
        try writeFile("Song 2.flac", in: folder, contents: "b")
        try writeFile("Song 3.flac", in: folder, contents: "c")
        let url = availableDestinationURL(in: folder, preferredName: "Song.flac")
        XCTAssertEqual(url.lastPathComponent, "Song 4.flac")
    }

    func testAvailableDestinationHandlesExtensionlessName() throws {
        let folder = try makeTemporaryDirectory()
        try writeFile("Notes", in: folder, contents: "x")
        let url = availableDestinationURL(in: folder, preferredName: "Notes")
        XCTAssertEqual(url.lastPathComponent, "Notes 2")
    }

    // MARK: - moveRenameFile

    func testMoveRenameMovesToNewName() throws {
        let folder = try makeTemporaryDirectory()
        let source = folder.appendingPathComponent("old.flac")
        try "audio".data(using: .utf8)?.write(to: source)
        let target = folder.appendingPathComponent("new.flac")

        try moveRenameFile(from: source, to: target)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testMoveRenameThrowsWhenTargetExists() throws {
        let folder = try makeTemporaryDirectory()
        let source = folder.appendingPathComponent("old.flac")
        let target = folder.appendingPathComponent("existing.flac")
        try "audio".data(using: .utf8)?.write(to: source)
        try "already here".data(using: .utf8)?.write(to: target)

        XCTAssertThrowsError(try moveRenameFile(from: source, to: target)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSCocoaErrorDomain)
            XCTAssertEqual(nsError.code, NSFileWriteFileExistsError)
        }
        // Source is untouched on the failed move.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMoveRenameHandlesCaseOnlyRename() throws {
        // On a case-preserving, case-insensitive filesystem, renaming
        // "song.flac" → "SONG.flac" must go through a temp file because the
        // two paths compare equal case-insensitively.
        let folder = try makeTemporaryDirectory()
        let source = folder.appendingPathComponent("song.flac")
        try "audio".data(using: .utf8)?.write(to: source)
        let target = folder.appendingPathComponent("SONG.flac")

        try moveRenameFile(from: source, to: target)

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let contents = try String(contentsOf: target, encoding: .utf8)
        XCTAssertEqual(contents, "audio")
    }

    // MARK: - encodedOutputFileName

    func testEncodedOutputFileNameAppendsEncodedForSameExtension() {
        let name = encodedOutputFileName(
            sourceExtension: "flac", baseName: "Song", formatExtension: "flac"
        )
        XCTAssertEqual(name, "Song-encoded.flac")
    }

    func testEncodedOutputFileNameKeepsBaseForDifferentExtension() {
        let name = encodedOutputFileName(
            sourceExtension: "wav", baseName: "Song", formatExtension: "flac"
        )
        XCTAssertEqual(name, "Song.flac")
    }

    func testEncodedOutputFileNameCaseInsensitiveSameExtensionCheck() {
        // Source extension uppercase, target lowercase — still treated as
        // same format → -encoded suffix.
        let name = encodedOutputFileName(
            sourceExtension: "FLAC", baseName: "Song", formatExtension: "flac"
        )
        XCTAssertEqual(name, "Song-encoded.flac")
    }

    func testEncodedOutputFileNameForVideoContainer() {
        let name = encodedOutputFileName(
            sourceExtension: "mov", baseName: "Clip", formatExtension: "mov"
        )
        XCTAssertEqual(name, "Clip-encoded.mov")
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPhilCoderPathTxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func writeFile(_ relativePath: String, in root: URL, contents: String) throws {
        let url = root.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.data(using: .utf8)?.write(to: url)
    }
}
