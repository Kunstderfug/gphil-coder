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
        XCTAssertTrue(
            MediaFileFilter.audio.matches(
                URL(fileURLWithPath: "/tmp/song.FLAC"),
                selectedExtensions: ["flac"]
            )
        )
        XCTAssertFalse(
            MediaFileFilter.audio.matches(
                URL(fileURLWithPath: "/tmp/dialogue.wav"),
                selectedExtensions: ["flac"]
            )
        )
        XCTAssertFalse(
            MediaFileFilter.video.matches(
                URL(fileURLWithPath: "/tmp/render.mp4"),
                selectedExtensions: []
            )
        )
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

    func testBuildPlanFiltersToSelectedExtensions() throws {
        let sourceRoot = try makeTemporaryDirectory()
        let destinationRoot = try makeTemporaryDirectory()
        try writeFile("Audio/song.flac", in: sourceRoot, contents: "flac")
        try writeFile("Audio/dialogue.wav", in: sourceRoot, contents: "wav")
        try writeFile("Video/clip.mov", in: sourceRoot, contents: "mov")

        let flacPlan = try MediaCopyPlanner.buildPlan(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            filter: .audio,
            selectedExtensions: ["flac"]
        )

        XCTAssertEqual(flacPlan.candidates.map(\.relativePath), ["Audio/song.flac"])
        XCTAssertEqual(flacPlan.selectedExtensions, Set(["flac"]))

        let emptySelectionPlan = try MediaCopyPlanner.buildPlan(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            filter: .audio,
            selectedExtensions: []
        )

        XCTAssertTrue(emptySelectionPlan.candidates.isEmpty)
    }

    func testBuildDeletePlanUsesSourceOnlyExtensionFilter() throws {
        let firstRoot = try makeTemporaryDirectory()
        let secondRoot = try makeTemporaryDirectory()
        try writeFile("Audio/song.flac", in: firstRoot, contents: "flac")
        try writeFile("Audio/dialogue.wav", in: firstRoot, contents: "wav")
        try writeFile("Video/clip.mov", in: secondRoot, contents: "mov")
        try writeFile("Notes/readme.txt", in: secondRoot, contents: "notes")

        let plan = try MediaCopyPlanner.buildDeletePlan(
            sourceRoots: [firstRoot, secondRoot],
            filter: .audio,
            selectedExtensions: ["flac"]
        )

        XCTAssertEqual(plan.candidates.map(\.relativePath), ["Audio/song.flac"])
        XCTAssertEqual(plan.candidates.first?.sourceRoot, firstRoot)
        XCTAssertEqual(plan.totalSizeBytes, Int64("flac".utf8.count))
    }

    func testInventorySnapshotFeedsDeleteAndRenamePlans() throws {
        let sourceRoot = try makeTemporaryDirectory()
        try writeFile("Audio/song.flac", in: sourceRoot, contents: "flac")
        try writeFile("Audio/dialogue.wav", in: sourceRoot, contents: "wav")
        try writeFile("Video/clip.mov", in: sourceRoot, contents: "mov")

        let inventory = try MediaCopyPlanner.scanFileInventory(sourceRoots: [sourceRoot])
        try FileManager.default.removeItem(
            at: sourceRoot.appendingPathComponent("Audio/song.flac")
        )

        let deletePlan = MediaCopyPlanner.buildDeletePlan(
            sourceRoots: [sourceRoot],
            filter: .audio,
            selectedExtensions: ["flac"],
            inventory: inventory
        )
        let renamePlan = MediaCopyPlanner.buildRenamePlan(
            sourceRoots: [sourceRoot],
            filter: .audio,
            selectedExtensions: ["wav"],
            settings: MediaRenameSettings(
                operation: .replaceText,
                findText: "dialogue",
                replacementText: "voice"
            ),
            inventory: inventory
        )

        XCTAssertEqual(deletePlan.candidates.map(\.relativePath), ["Audio/song.flac"])
        XCTAssertEqual(renamePlan.items.map(\.newName), ["voice.wav"])
    }

    func testBuildRenamePlanAppliesPatternAndIndexToSelectedExtensions() throws {
        let sourceRoot = try makeTemporaryDirectory()
        try writeFile("Audio/song.flac", in: sourceRoot, contents: "song")
        try writeFile("Audio/dialogue.flac", in: sourceRoot, contents: "dialogue")
        try writeFile("Audio/skip.wav", in: sourceRoot, contents: "skip")

        let plan = try MediaCopyPlanner.buildRenamePlan(
            sourceRoots: [sourceRoot],
            filter: .audio,
            selectedExtensions: ["flac"],
            settings: MediaRenameSettings(
                operation: .pattern,
                pattern: "Track {index} - {name}",
                sort: .name,
                startIndex: 1,
                indexPadding: 2
            )
        )

        XCTAssertEqual(plan.items.map(\.originalName), ["dialogue.flac", "song.flac"])
        XCTAssertEqual(plan.items.map(\.newName), ["Track 01 - dialogue.flac", "Track 02 - song.flac"])
        XCTAssertEqual(plan.readyCount, 2)
        XCTAssertEqual(plan.blockedCount, 0)
    }

    func testBuildRenamePlanAppliesModifiedDatePatternVariable() throws {
        let sourceRoot = try makeTemporaryDirectory()
        let fileURL = sourceRoot.appendingPathComponent("Audio/song.flac")
        try writeFile("Audio/song.flac", in: sourceRoot, contents: "song")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_710_421_200)],
            ofItemAtPath: fileURL.path
        )

        let plan = try MediaCopyPlanner.buildRenamePlan(
            sourceRoots: [sourceRoot],
            filter: .audio,
            selectedExtensions: ["flac"],
            settings: MediaRenameSettings(
                operation: .pattern,
                pattern: "{date} - {name}"
            )
        )

        XCTAssertEqual(plan.items.first?.newName, "2024-03-14 - song.flac")
        XCTAssertEqual(plan.items.first?.state, .ready)
    }

    func testBuildRenamePlanAutoIndexesFromUserStartIndex() throws {
        let sourceRoot = try makeTemporaryDirectory()
        try writeFile("Audio/song.flac", in: sourceRoot, contents: "song")
        try writeFile("Audio/dialogue.flac", in: sourceRoot, contents: "dialogue")

        let plan = try MediaCopyPlanner.buildRenamePlan(
            sourceRoots: [sourceRoot],
            filter: .audio,
            selectedExtensions: ["flac"],
            settings: MediaRenameSettings(
                operation: .autoIndex,
                sort: .name,
                startIndex: 12,
                indexStep: 3,
                indexPadding: 4
            )
        )

        XCTAssertEqual(plan.items.map(\.originalName), ["dialogue.flac", "song.flac"])
        XCTAssertEqual(plan.items.map(\.newName), ["0012.flac", "0015.flac"])
        XCTAssertEqual(plan.readyCount, 2)
        XCTAssertEqual(plan.blockedCount, 0)
    }

    func testBuildRenamePlanReplacesTextAndPreservesExtension() throws {
        let sourceRoot = try makeTemporaryDirectory()
        try writeFile("Audio/old_song.wav", in: sourceRoot, contents: "audio")

        let plan = try MediaCopyPlanner.buildRenamePlan(
            sourceRoots: [sourceRoot],
            filter: .audio,
            selectedExtensions: ["wav"],
            settings: MediaRenameSettings(
                operation: .replaceText,
                findText: "OLD",
                replacementText: "new",
                isCaseSensitive: false
            )
        )

        XCTAssertEqual(plan.items.first?.newName, "new_song.wav")
        XCTAssertEqual(plan.items.first?.state, .ready)
    }

    func testBuildRenamePlanAddsIndexTextBeforeOrAfterName() throws {
        let sourceRoot = try makeTemporaryDirectory()
        try writeFile("Audio/song.flac", in: sourceRoot, contents: "audio")

        let suffixPlan = try MediaCopyPlanner.buildRenamePlan(
            sourceRoots: [sourceRoot],
            filter: .audio,
            selectedExtensions: ["flac"],
            settings: MediaRenameSettings(
                operation: .addText,
                addedText: "-{index}",
                textPlacement: .suffix,
                startIndex: 7,
                indexPadding: 3
            )
        )
        let prefixPlan = try MediaCopyPlanner.buildRenamePlan(
            sourceRoots: [sourceRoot],
            filter: .audio,
            selectedExtensions: ["flac"],
            settings: MediaRenameSettings(
                operation: .addText,
                addedText: "Take {index} - ",
                textPlacement: .prefix,
                startIndex: 7,
                indexPadding: 3
            )
        )

        XCTAssertEqual(suffixPlan.items.first?.newName, "song-007.flac")
        XCTAssertEqual(prefixPlan.items.first?.newName, "Take 007 - song.flac")
    }

    func testBuildRenamePlanDetectsDuplicateTargets() throws {
        let sourceRoot = try makeTemporaryDirectory()
        try writeFile("Audio/one.wav", in: sourceRoot, contents: "one")
        try writeFile("Audio/two.wav", in: sourceRoot, contents: "two")

        let plan = try MediaCopyPlanner.buildRenamePlan(
            sourceRoots: [sourceRoot],
            filter: .audio,
            selectedExtensions: ["wav"],
            settings: MediaRenameSettings(
                operation: .pattern,
                pattern: "same"
            )
        )

        XCTAssertEqual(plan.blockedCount, 2)
        XCTAssertTrue(plan.items.allSatisfy { $0.state == .duplicate })
    }

    func testBuildRenamePlanSupportsCaseTransforms() throws {
        let sourceRoot = try makeTemporaryDirectory()
        try writeFile("Audio/mixed CASE.mp3", in: sourceRoot, contents: "audio")

        let uppercasePlan = try MediaCopyPlanner.buildRenamePlan(
            sourceRoots: [sourceRoot],
            filter: .audio,
            selectedExtensions: ["mp3"],
            settings: MediaRenameSettings(operation: .changeCase, caseStyle: .uppercase)
        )
        let lowercasePlan = try MediaCopyPlanner.buildRenamePlan(
            sourceRoots: [sourceRoot],
            filter: .audio,
            selectedExtensions: ["mp3"],
            settings: MediaRenameSettings(operation: .changeCase, caseStyle: .lowercase)
        )
        let capitalizedPlan = try MediaCopyPlanner.buildRenamePlan(
            sourceRoots: [sourceRoot],
            filter: .audio,
            selectedExtensions: ["mp3"],
            settings: MediaRenameSettings(operation: .changeCase, caseStyle: .titleCase)
        )

        XCTAssertEqual(uppercasePlan.items.first?.newName, "MIXED CASE.mp3")
        XCTAssertEqual(lowercasePlan.items.first?.newName, "mixed case.mp3")
        XCTAssertEqual(capitalizedPlan.items.first?.newName, "Mixed Case.mp3")
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
            selectedExtensions: nil,
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
        XCTAssertNil(decoded.workflows.first?.selectedExtensions)
    }

    func testMediaCopyJobDocumentRoundTripsSelectedExtensions() throws {
        let workflow = MediaCopyWorkflow(
            sourceRoot: URL(fileURLWithPath: "/Volumes/Source", isDirectory: true),
            destinationRoot: URL(fileURLWithPath: "/Volumes/Target", isDirectory: true),
            filter: .video,
            selectedExtensions: ["mov", "mp4"],
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

        XCTAssertEqual(decoded.workflows.first?.filter, .video)
        XCTAssertEqual(decoded.workflows.first?.selectedExtensions, Set(["mov", "mp4"]))
    }

    func testMediaCopyJobDocumentDecodesLegacyWorkflowWithoutSelectedExtensions() throws {
        let data = """
            {
              "version": 1,
              "savedAt": "2026-05-17T00:00:00Z",
              "workflows": [
                {
                  "id": "00000000-0000-0000-0000-000000000001",
                  "sourceRoot": "/Volumes/Source",
                  "destinationRoot": "/Volumes/Target",
                  "filter": "audio",
                  "createdAt": "2026-05-17T00:00:00Z"
                }
              ]
            }
            """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MediaCopyJobDocument.self, from: data)

        XCTAssertEqual(decoded.workflows.first?.filter, .audio)
        XCTAssertNil(decoded.workflows.first?.selectedExtensions)
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
