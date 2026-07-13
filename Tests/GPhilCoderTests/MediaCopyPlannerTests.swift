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

    func testBuildPlanFiltersByFileNameText() throws {
        let sourceRoot = try makeTemporaryDirectory()
        let destinationRoot = try makeTemporaryDirectory()
        try writeFile("Audio/camera_001.wav", in: sourceRoot, contents: "one")
        try writeFile("Audio/camera_002.wav", in: sourceRoot, contents: "two")
        try writeFile("Audio/roomtone.wav", in: sourceRoot, contents: "tone")

        let plan = try MediaCopyPlanner.buildPlan(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            filter: .audio,
            selectedExtensions: ["wav"],
            fileNameFilter: MediaFileNameFilter(query: "CAMERA_")
        )

        XCTAssertEqual(plan.candidates.map(\.relativePath), ["Audio/camera_001.wav", "Audio/camera_002.wav"])
    }

    func testBuildPlanCanLimitPreviewCandidatesWhileKeepingTotals() throws {
        let sourceRoot = try makeTemporaryDirectory()
        let destinationRoot = try makeTemporaryDirectory()
        try writeFile("Audio/take_001.wav", in: sourceRoot, contents: "one")
        try writeFile("Audio/take_002.wav", in: sourceRoot, contents: "two")
        try writeFile("Audio/take_003.wav", in: sourceRoot, contents: "three")

        let plan = try MediaCopyPlanner.buildPlan(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            filter: .audio,
            selectedExtensions: ["wav"],
            candidateLimit: 2
        )

        XCTAssertEqual(plan.candidateCount, 3)
        XCTAssertEqual(plan.candidates.count, 2)
        XCTAssertTrue(plan.candidates.allSatisfy { $0.relativePath.hasPrefix("Audio/take_") })
        XCTAssertEqual(plan.totalSizeBytes, Int64("onetwothree".utf8.count))
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

    func testBuildDeletePlanAllFilesIncludesNonMediaFiles() throws {
        let sourceRoot = try makeTemporaryDirectory()
        try writeFile("Audio/song.flac", in: sourceRoot, contents: "song")
        try writeFile("Docs/readme.txt", in: sourceRoot, contents: "notes")
        try writeFile("Images/cover.jpg", in: sourceRoot, contents: "image")

        let plan = try MediaCopyPlanner.buildDeletePlan(
            sourceRoots: [sourceRoot],
            filter: .all,
            selectedExtensions: []
        )

        XCTAssertEqual(
            plan.candidates.map(\.relativePath),
            ["Audio/song.flac", "Docs/readme.txt", "Images/cover.jpg"]
        )
    }

    func testBuildDeletePlanFiltersByFileNameText() throws {
        let sourceRoot = try makeTemporaryDirectory()
        try writeFile("Batch/take_001.txt", in: sourceRoot, contents: "one")
        try writeFile("Batch/take_002.txt", in: sourceRoot, contents: "two")
        try writeFile("Batch/notes.txt", in: sourceRoot, contents: "notes")

        let plan = try MediaCopyPlanner.buildDeletePlan(
            sourceRoots: [sourceRoot],
            filter: .all,
            selectedExtensions: [],
            fileNameFilter: MediaFileNameFilter(query: "take_")
        )

        XCTAssertEqual(plan.candidates.map(\.relativePath), ["Batch/take_001.txt", "Batch/take_002.txt"])
    }

    func testBuildDeletePlanCanLimitPreviewCandidatesWhileKeepingTotals() throws {
        let sourceRoot = try makeTemporaryDirectory()
        try writeFile("Batch/take_001.txt", in: sourceRoot, contents: "one")
        try writeFile("Batch/take_002.txt", in: sourceRoot, contents: "two")
        try writeFile("Batch/take_003.txt", in: sourceRoot, contents: "three")

        let plan = try MediaCopyPlanner.buildDeletePlan(
            sourceRoots: [sourceRoot],
            filter: .all,
            selectedExtensions: [],
            candidateLimit: 2
        )

        XCTAssertEqual(plan.candidateCount, 3)
        XCTAssertEqual(plan.candidates.map(\.relativePath), ["Batch/take_001.txt", "Batch/take_002.txt"])
        XCTAssertEqual(plan.totalSizeBytes, Int64("onetwothree".utf8.count))
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

    func testBuildRenamePlanFiltersByFileNameText() throws {
        let sourceRoot = try makeTemporaryDirectory()
        try writeFile("Audio/camera_001.wav", in: sourceRoot, contents: "one")
        try writeFile("Audio/camera_002.wav", in: sourceRoot, contents: "two")
        try writeFile("Audio/roomtone.wav", in: sourceRoot, contents: "tone")

        let plan = try MediaCopyPlanner.buildRenamePlan(
            sourceRoots: [sourceRoot],
            filter: .audio,
            selectedExtensions: ["wav"],
            fileNameFilter: MediaFileNameFilter(query: "camera_"),
            settings: MediaRenameSettings(
                operation: .autoIndex,
                startIndex: 1,
                indexPadding: 2
            )
        )

        XCTAssertEqual(plan.items.map(\.originalName), ["camera_001.wav", "camera_002.wav"])
        XCTAssertEqual(plan.items.map(\.newName), ["01.wav", "02.wav"])
    }

    func testBuildRenamePlanCanLimitPreviewItemsWhileKeepingCounts() throws {
        let sourceRoot = try makeTemporaryDirectory()
        try writeFile("Audio/take_001.wav", in: sourceRoot, contents: "one")
        try writeFile("Audio/take_002.wav", in: sourceRoot, contents: "two")
        try writeFile("Audio/take_003.wav", in: sourceRoot, contents: "three")

        let plan = try MediaCopyPlanner.buildRenamePlan(
            sourceRoots: [sourceRoot],
            filter: .audio,
            selectedExtensions: ["wav"],
            itemLimit: 2,
            settings: MediaRenameSettings(
                operation: .autoIndex,
                startIndex: 1,
                indexPadding: 2
            )
        )

        XCTAssertEqual(plan.itemCount, 3)
        XCTAssertEqual(plan.items.map(\.originalName), ["take_001.wav", "take_002.wav"])
        XCTAssertEqual(plan.readyCount, 3)
        XCTAssertEqual(plan.totalSizeBytes, Int64("onetwothree".utf8.count))
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

    func testBatchPreviewIdentifiesEachSourceAndSharesVisibleRowsAcrossSources() throws {
        let workspace = try makeTemporaryDirectory()
        let firstSource = workspace.appendingPathComponent("First", isDirectory: true)
        let secondSource = workspace.appendingPathComponent("Second", isDirectory: true)
        let destination = workspace.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: firstSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try writeFile("Audio/a.wav", in: firstSource, contents: "a")
        try writeFile("Audio/b.wav", in: firstSource, contents: "b")
        try writeFile("Audio/c.wav", in: secondSource, contents: "c")

        let plan = try MediaCopyBatchPlanner.buildPlan(
            configuration: MediaCopyBatchConfiguration(
                sourceRoots: [firstSource, secondSource],
                destinationRoot: destination,
                filter: .audio
            ),
            candidateLimit: 2
        )

        XCTAssertEqual(plan.candidateCount, 3)
        XCTAssertEqual(plan.candidates.count, 2)
        XCTAssertEqual(Set(plan.candidates.map(\.sourceRoot)), Set([firstSource, secondSource]))
    }

    func testBatchPlanReportsCollisionsBetweenSelectedSources() throws {
        let workspace = try makeTemporaryDirectory()
        let firstSource = workspace.appendingPathComponent("First", isDirectory: true)
        let secondSource = workspace.appendingPathComponent("Second", isDirectory: true)
        let destination = workspace.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: firstSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try writeFile("Audio/take.wav", in: firstSource, contents: "first")
        try writeFile("Audio/take.wav", in: secondSource, contents: "second")

        let plan = try MediaCopyBatchPlanner.buildPlan(
            configuration: MediaCopyBatchConfiguration(
                sourceRoots: [firstSource, secondSource],
                destinationRoot: destination,
                destinationLayout: .mergeContents,
                filter: .audio
            )
        )

        XCTAssertEqual(plan.candidateCount, 2)
        XCTAssertEqual(plan.conflictCount, 2)
        XCTAssertEqual(plan.copyableWithoutOverwriteCount, 1)
        XCTAssertTrue(plan.candidates.allSatisfy(\.hasDestinationConflict))
    }

    func testBatchPlanBlocksAncestorDestinationCollisions() throws {
        let workspace = try makeTemporaryDirectory()
        let firstSource = try makeDirectory("First", in: workspace)
        let secondSource = try makeDirectory("Second", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("shared", in: firstSource, contents: "file")
        try writeFile("shared/inside.txt", in: secondSource, contents: "nested")

        let plan = try MediaCopyBatchPlanner.buildPlan(
            configuration: MediaCopyBatchConfiguration(
                sourceRoots: [firstSource, secondSource],
                destinationRoot: destination,
                destinationLayout: .mergeContents,
                filter: .all
            )
        )

        XCTAssertEqual(plan.structuralConflictCount, 3)
        XCTAssertFalse(plan.canExecute)
        XCTAssertTrue(plan.candidates.allSatisfy(\.hasDestinationConflict))
    }

    func testBatchPlanBlocksRegularFileReplacingAnExistingDirectory() throws {
        let workspace = try makeTemporaryDirectory()
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("shared", in: source, contents: "file")
        _ = try makeDirectory("shared", in: destination)

        let plan = try MediaCopyBatchPlanner.buildPlan(
            configuration: MediaCopyBatchConfiguration(
                sourceRoots: [source],
                destinationRoot: destination,
                destinationLayout: .mergeContents,
                filter: .all
            )
        )

        XCTAssertEqual(plan.structuralConflictCount, 1)
        XCTAssertFalse(plan.canExecute)
        XCTAssertTrue(try XCTUnwrap(plan.candidates.first).hasDestinationConflict)
    }

    func testBatchPlanDetectsCaseOnlyCollisionsOnCaseInsensitiveDestination() throws {
        let workspace = try makeTemporaryDirectory()
        let firstSource = try makeDirectory("First", in: workspace)
        let secondSource = try makeDirectory("Second", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let caseSensitive = try destination.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        ).volumeSupportsCaseSensitiveNames ?? true
        if caseSensitive {
            throw XCTSkip("Case-only collision behavior requires a case-insensitive volume.")
        }
        try writeFile("Audio/Take.wav", in: firstSource, contents: "first")
        try writeFile("Audio/take.wav", in: secondSource, contents: "second")

        let plan = try MediaCopyBatchPlanner.buildPlan(
            configuration: MediaCopyBatchConfiguration(
                sourceRoots: [firstSource, secondSource],
                destinationRoot: destination,
                destinationLayout: .mergeContents,
                filter: .audio
            )
        )

        XCTAssertFalse(plan.destinationUsesCaseSensitiveNames)
        XCTAssertEqual(plan.conflictCount, 2)
        XCTAssertTrue(plan.candidates.allSatisfy(\.hasDestinationConflict))
    }

    func testQueueReviewDetectsCollisionsAcrossSeparatelyPlannedWorkflows() throws {
        let workspace = try makeTemporaryDirectory()
        let firstSource = try makeDirectory("First", in: workspace)
        let secondSource = try makeDirectory("Second", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try writeFile("Audio/take.wav", in: firstSource, contents: "first")
        try writeFile("Audio/take.wav", in: secondSource, contents: "second")

        let plans = try [firstSource, secondSource].map { source in
            try MediaCopyBatchPlanner.buildPlan(
                configuration: MediaCopyBatchConfiguration(
                    sourceRoots: [source],
                    destinationRoot: destination,
                    destinationLayout: .mergeContents,
                    filter: .audio
                )
            )
        }
        XCTAssertEqual(plans.reduce(0) { $0 + $1.conflictCount }, 0)

        let queueReviewPlans = MediaCopyBatchPlanner.buildQueueReviewPlans(from: plans)

        XCTAssertEqual(queueReviewPlans.count, 1)
        XCTAssertEqual(queueReviewPlans[0].conflictCount, 2)
        XCTAssertTrue(queueReviewPlans[0].candidates.allSatisfy(\.hasDestinationConflict))
    }

    func testSourceFoldersLayoutAlwaysPlacesSourceInsideSelectedDestination() {
        let source = URL(fileURLWithPath: "/Origin/Session", isDirectory: true)
        let destination = URL(fileURLWithPath: "/Delivery/Session", isDirectory: true)

        XCTAssertEqual(
            MediaCopyDestinationLayout.sourceFolders
                .resolvedDestinationRoot(for: source, destinationRoot: destination)
                .standardizedFileURL.path,
            "/Delivery/Session/Session"
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

    func testCopyTreatsMacOSPackageAsOneCompleteCandidate() throws {
        let sourceRoot = try makeTemporaryDirectory()
        let destinationRoot = try makeTemporaryDirectory()
        try writeFile(
            "Session.app/Contents/Info.plist",
            in: sourceRoot,
            contents: "package metadata"
        )
        try writeFile(
            "Session.app/Contents/Resources/payload.dat",
            in: sourceRoot,
            contents: "package payload"
        )

        let plan = try MediaCopyPlanner.buildPlan(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            filter: .all
        )
        let candidate = try XCTUnwrap(plan.candidates.first)

        XCTAssertEqual(plan.candidateCount, 1)
        XCTAssertEqual(plan.relativeDirectories, [])
        XCTAssertTrue(candidate.isPackage)
        XCTAssertEqual(
            MediaCopyPlanner.copyCandidate(candidate, conflictResolution: .skipExisting),
            .copied
        )
        XCTAssertEqual(
            try readFile("Session.app/Contents/Info.plist", in: destinationRoot),
            "package metadata"
        )
        XCTAssertEqual(
            try readFile("Session.app/Contents/Resources/payload.dat", in: destinationRoot),
            "package payload"
        )
    }

    func testMediaCopyJobDocumentRoundTripsQueuedWorkflows() throws {
        let sourceRoot = URL(fileURLWithPath: "/Volumes/Source/FESTIVAL_MEDIA_FILES", isDirectory: true)
        let secondSourceRoot = URL(fileURLWithPath: "/Volumes/Source/SECOND_CAMERA", isDirectory: true)
        let destinationRoot = URL(fileURLWithPath: "/Volumes/Target/FESTIVAL_MEDIA_FILES", isDirectory: true)
        let workflow = MediaCopyWorkflow(
            sourceRoots: [sourceRoot, secondSourceRoot],
            destinationRoot: destinationRoot,
            destinationLayout: .mergeContents,
            filter: .all,
            selectedExtensions: nil,
            fileNameFilter: MediaFileNameFilter(query: "take_"),
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
        XCTAssertEqual(decoded.workflows.first?.sourceRoots, [sourceRoot, secondSourceRoot])
        XCTAssertEqual(decoded.workflows.first?.destinationRoot, destinationRoot)
        XCTAssertEqual(decoded.workflows.first?.destinationLayout, .mergeContents)
        XCTAssertEqual(decoded.workflows.first?.filter, .all)
        XCTAssertNil(decoded.workflows.first?.selectedExtensions)
        XCTAssertEqual(decoded.workflows.first?.fileNameFilter, MediaFileNameFilter(query: "take_"))
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
        XCTAssertEqual(decoded.version, MediaCopyJobDocument.currentVersion)
        XCTAssertEqual(
            decoded.workflows.first?.sourceRoots,
            [URL(fileURLWithPath: "/Volumes/Source", isDirectory: true)]
        )
        XCTAssertEqual(decoded.workflows.first?.destinationLayout, .mergeContents)
        XCTAssertEqual(
            decoded.workflows.first?.destinationRoot.standardizedFileURL.path,
            "/Volumes/Target/Source"
        )
        XCTAssertNil(decoded.workflows.first?.selectedExtensions)
        XCTAssertEqual(decoded.workflows.first?.fileNameFilter, MediaFileNameFilter())
    }

    func testMediaCopyJobDocumentRejectsFutureVersionPrecisely() throws {
        let data = """
            {
              "version": \(MediaCopyJobDocument.currentVersion + 1),
              "savedAt": "2026-07-13T00:00:00Z",
              "workflows": []
            }
            """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertThrowsError(try decoder.decode(MediaCopyJobDocument.self, from: data)) { error in
            XCTAssertEqual(
                error as? MediaCopyJobDocumentError,
                .unsupportedVersion(
                    found: MediaCopyJobDocument.currentVersion + 1,
                    supported: MediaCopyJobDocument.currentVersion
                )
            )
        }
    }

    func testSavedWorkflowRetainsMissingFoldersAndCanRelinkThem() throws {
        let missingSource = URL(fileURLWithPath: "/Volumes/Missing/Source", isDirectory: true)
        let missingDestination = URL(
            fileURLWithPath: "/Volumes/Missing/Destination",
            isDirectory: true
        )
        let replacementSource = try makeTemporaryDirectory()
        let workflow = MediaCopyWorkflow(
            sourceRoots: [missingSource],
            destinationRoot: missingDestination,
            destinationLayout: .mergeContents,
            filter: .audio
        )
        let data = try JSONEncoder().encode(MediaCopyJobDocument(workflows: [workflow]))

        let decoded = try JSONDecoder().decode(MediaCopyJobDocument.self, from: data)

        let retained = try XCTUnwrap(decoded.workflows.first)
        XCTAssertEqual(retained.repairIssues, [
            .missingSource(missingSource),
            .missingDestination(missingDestination),
        ])

        let relinked = retained.replacingSourceRoot(missingSource, with: replacementSource)
        XCTAssertEqual(relinked.sourceRoots, [replacementSource])
        XCTAssertEqual(relinked.repairIssues, [.missingDestination(missingDestination)])
        XCTAssertEqual(relinked.destinationLayout, .mergeContents)
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

    func testVersionTwoSourceFoldersLayoutDoesNotUseLegacyLeafNameHeuristic() {
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
            matchingDestinationRoot.appendingPathComponent("FESTIVAL_MEDIA_FILES")
                .standardizedFileURL.path
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPhilCoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func makeDirectory(_ relativePath: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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
