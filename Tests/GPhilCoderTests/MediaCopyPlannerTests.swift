import Foundation
import XCTest
@testable import GPhilCoderCore

final class MediaCopyPlannerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testMediaFiltersMatchCommonExtensionsCaseInsensitively() {
        XCTAssertTrue(MediaFileFilter.audio.matches(URL(fileURLWithPath: "/tmp/song.FLAC")))
        XCTAssertTrue(MediaFileFilter.audio.matches(URL(fileURLWithPath: "/tmp/dialogue.wav")))
        XCTAssertTrue(MediaFileFilter.video.matches(URL(fileURLWithPath: "/tmp/clip.MOV")))
        XCTAssertTrue(MediaFileFilter.video.matches(URL(fileURLWithPath: "/tmp/render.mp4")))
        XCTAssertTrue(MediaFileFilter.all.matches(URL(fileURLWithPath: "/tmp/readme.txt")))
        XCTAssertTrue(MediaFileFilter.all.matches(URL(fileURLWithPath: "/tmp/archive.zip")))
        XCTAssertFalse(MediaFileFilter.audio.matches(URL(fileURLWithPath: "/tmp/clip.mov")))
        XCTAssertFalse(MediaFileFilter.video.matches(URL(fileURLWithPath: "/tmp/song.aiff")))
    }

    func testBuildPlanPreservesRelativeFoldersAndDetectsConflicts() throws {
        let sourceRoot = try makeTemporaryDirectory().appendingPathComponent(
            "FESTIVAL_MEDIA_FILES",
            isDirectory: true
        )
        let destinationRoot = try makeTemporaryDirectory().appendingPathComponent(
            "FESTIVAL_MEDIA_FILES",
            isDirectory: true
        )

        try writeFile("Audio/Day 1/Main Stage/song.flac", in: sourceRoot, contents: "source")
        try writeFile("Audio/Day 1/Main Stage/song.flac", in: destinationRoot, contents: "target")
        try writeFile("Video/Day 1/Main Stage/clip.mov", in: sourceRoot, contents: "video")
        try writeFile("Notes/readme.txt", in: sourceRoot, contents: "ignore")

        let audioPlan = try MediaCopyPlanner.buildPlan(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            filter: .audio
        )

        XCTAssertEqual(audioPlan.candidates.map(\.relativePath), ["Audio/Day 1/Main Stage/song.flac"])
        XCTAssertEqual(audioPlan.conflictCount, 1)
        XCTAssertEqual(audioPlan.copyableWithoutOverwriteCount, 0)
        XCTAssertEqual(
            audioPlan.candidates.first?.destinationURL.standardizedFileURL.path,
            destinationRoot
                .appendingPathComponent("Audio/Day 1/Main Stage/song.flac")
                .standardizedFileURL.path
        )

        let videoPlan = try MediaCopyPlanner.buildPlan(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            filter: .video
        )

        XCTAssertEqual(videoPlan.candidates.map(\.relativePath), ["Video/Day 1/Main Stage/clip.mov"])
        XCTAssertEqual(videoPlan.conflictCount, 0)
    }

    func testAllFilesPlanIncludesEveryRegularFileAndRelativeDirectories() throws {
        let sourceRoot = try makeTemporaryDirectory()
        let destinationRoot = try makeTemporaryDirectory()
        try writeFile("Audio/song.flac", in: sourceRoot, contents: "audio")
        try writeFile("Video/clip.mov", in: sourceRoot, contents: "video")
        try writeFile("Notes/readme.txt", in: sourceRoot, contents: "notes")
        try FileManager.default.createDirectory(
            at: sourceRoot.appendingPathComponent("Empty/Child", isDirectory: true),
            withIntermediateDirectories: true
        )

        let plan = try MediaCopyPlanner.buildPlan(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            filter: .all
        )

        XCTAssertEqual(
            plan.candidates.map(\.relativePath),
            ["Audio/song.flac", "Notes/readme.txt", "Video/clip.mov"]
        )
        XCTAssertTrue(plan.relativeDirectories.contains("Empty"))
        XCTAssertTrue(plan.relativeDirectories.contains("Empty/Child"))
        XCTAssertEqual(MediaCopyPlanner.createDirectories(for: plan), [])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destinationRoot.appendingPathComponent("Empty/Child").path
            )
        )
    }

    func testCopyCandidateCreatesDestinationSubfolders() throws {
        let sourceRoot = try makeTemporaryDirectory()
        let destinationRoot = try makeTemporaryDirectory()
        try writeFile("Audio/Sub/song.wav", in: sourceRoot, contents: "new audio")

        let candidate = try XCTUnwrap(
            MediaCopyPlanner.buildPlan(
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot,
                filter: .audio
            ).candidates.first
        )

        XCTAssertEqual(
            MediaCopyPlanner.copyCandidate(candidate, conflictResolution: .skipExisting),
            .copied
        )
        XCTAssertEqual(
            try readFile("Audio/Sub/song.wav", in: destinationRoot),
            "new audio"
        )
    }

    func testCopyCandidateSkipsExistingDestinationFiles() throws {
        let sourceRoot = try makeTemporaryDirectory()
        let destinationRoot = try makeTemporaryDirectory()
        try writeFile("Audio/song.mp3", in: sourceRoot, contents: "new")
        try writeFile("Audio/song.mp3", in: destinationRoot, contents: "old")

        let candidate = try XCTUnwrap(
            MediaCopyPlanner.buildPlan(
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot,
                filter: .audio
            ).candidates.first
        )

        XCTAssertEqual(
            MediaCopyPlanner.copyCandidate(candidate, conflictResolution: .skipExisting),
            .skippedExisting
        )
        XCTAssertEqual(try readFile("Audio/song.mp3", in: destinationRoot), "old")
    }

    func testCopyCandidateReplacesExistingDestinationFiles() throws {
        let sourceRoot = try makeTemporaryDirectory()
        let destinationRoot = try makeTemporaryDirectory()
        try writeFile("Audio/song.mp3", in: sourceRoot, contents: "new")
        try writeFile("Audio/song.mp3", in: destinationRoot, contents: "old")

        let candidate = try XCTUnwrap(
            MediaCopyPlanner.buildPlan(
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot,
                filter: .audio
            ).candidates.first
        )

        XCTAssertEqual(
            MediaCopyPlanner.copyCandidate(candidate, conflictResolution: .replaceExisting),
            .copied
        )
        XCTAssertEqual(try readFile("Audio/song.mp3", in: destinationRoot), "new")
    }

    func testMediaCopyJobDocumentRoundTripsQueuedWorkflows() throws {
        let sourceRoot = URL(fileURLWithPath: "/Volumes/Source/FESTIVAL_MEDIA_FILES", isDirectory: true)
        let destinationRoot = URL(fileURLWithPath: "/Volumes/Target/FESTIVAL_MEDIA_FILES", isDirectory: true)
        let workflow = MediaCopyWorkflow(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            filter: .all,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let document = MediaCopyJobDocument(
            savedAt: Date(timeIntervalSince1970: 1_800_000_100),
            workflows: [workflow]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MediaCopyJobDocument.self, from: data)

        XCTAssertEqual(decoded.version, MediaCopyJobDocument.currentVersion)
        XCTAssertEqual(decoded.workflows.count, 1)
        XCTAssertEqual(decoded.workflows.first?.sourceRoot, sourceRoot)
        XCTAssertEqual(decoded.workflows.first?.destinationRoot, destinationRoot)
        XCTAssertEqual(decoded.workflows.first?.filter, .all)
    }

    func testQueuedWorkflowDestinationPreservesSourceFolderName() {
        let sourceRoot = URL(
            fileURLWithPath: "/Volumes/Source/FESTIVAL_MEDIA_FILES",
            isDirectory: true
        )
        let destinationParent = URL(fileURLWithPath: "/Volumes/Target", isDirectory: true)
        let workflow = MediaCopyWorkflow(
            sourceRoot: sourceRoot,
            destinationRoot: destinationParent,
            filter: .all
        )

        XCTAssertEqual(
            workflow.destinationRootPreservingSourceFolder.standardizedFileURL.path,
            "/Volumes/Target/FESTIVAL_MEDIA_FILES"
        )
    }

    func testQueuedWorkflowDoesNotDuplicateSourceFolderNameWhenDestinationAlreadyMatches() {
        let sourceRoot = URL(
            fileURLWithPath: "/Volumes/Source/FESTIVAL_MEDIA_FILES",
            isDirectory: true
        )
        let matchingDestinationRoot = URL(
            fileURLWithPath: "/Volumes/Target/FESTIVAL_MEDIA_FILES",
            isDirectory: true
        )
        let workflow = MediaCopyWorkflow(
            sourceRoot: sourceRoot,
            destinationRoot: matchingDestinationRoot,
            filter: .audio
        )

        XCTAssertEqual(
            workflow.destinationRootPreservingSourceFolder.standardizedFileURL.path,
            matchingDestinationRoot.standardizedFileURL.path
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPhilCoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func writeFile(_ relativePath: String, in root: URL, contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.data(using: .utf8)?.write(to: url)
    }

    private func readFile(_ relativePath: String, in root: URL) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
