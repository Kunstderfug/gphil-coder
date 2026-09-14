import Foundation
import GPhilCoderCore
import XCTest
@testable import GPhilCoder

/// Frozen final-gate suite for ticket 004: the current File Copy queue can be
/// saved under a chosen name and later loaded as the same workflows.
///
/// Every row drives the real composition root (`EncoderViewModel`, the object
/// the Copy Queue UI binds) against a test-controlled persistence directory,
/// mutates the library through the Save as Workflow / Load Workflow / Delete
/// Workflow entry points the UI calls, and then composes a fresh model from
/// the same directory to assert the reloaded library and loaded queue.
@MainActor
final class MediaCopySavedWorkflowTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        clearViewModelDefaultsForTests()
    }

    override func tearDownWithError() throws {
        MediaCopyAppKitBoundary.savedWorkflowNameProvider =
            MediaCopySavedWorkflowTests.defaultSavedWorkflowNameProvider
        MediaCopyAppKitBoundary.deleteSavedWorkflowConfirmProvider =
            MediaCopySavedWorkflowTests.defaultDeleteSavedWorkflowConfirmProvider
        MediaCopyAppKitBoundary.repairDirectoryProvider =
            MediaCopySavedWorkflowTests.defaultRepairDirectoryProvider
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        clearViewModelDefaultsForTests()
        try super.tearDownWithError()
    }

    // MARK: - Save persists; a fresh composition reloads identically

    func testSavingNamedQueuePersistsWorkflowsAFreshModelReloadsIdentically() throws {
        let workspace = try makeTemporaryDirectory()
        let queueStorageRoot = try makeDirectory("QueueStorage", in: workspace)
        let libraryStorageRoot = try makeDirectory("LibraryStorage", in: workspace)
        let firstSource = try makeDirectory("FirstSource", in: workspace)
        try writeFile("Audio/take01.wav", in: firstSource, contents: "take one")
        let secondSource = try makeDirectory("SecondSource", in: workspace)
        try writeFile("Audio/take02.aiff", in: secondSource, contents: "take two")
        try writeFile("Video/take03.mov", in: secondSource, contents: "take three")
        let destination = try makeDirectory("Destination", in: workspace)
        let destinationFingerprintBefore = try treeFingerprint(of: destination)

        let emptyModel = makeModel(
            queueStorageRoot: queueStorageRoot,
            libraryStorageRoot: libraryStorageRoot
        )
        XCTAssertTrue(emptyModel.mediaCopySavedWorkflows.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: MediaCopySavedWorkflowLibrary(directoryURL: libraryStorageRoot).documentURL.path
            ),
            "A missing library document must not write an empty file at composition."
        )

        let model = makeModel(
            queueStorageRoot: queueStorageRoot,
            libraryStorageRoot: libraryStorageRoot
        )
        model.mediaCopySourceRoots = [firstSource]
        model.mediaCopyDestinationRoot = destination
        model.mediaCopyDestinationLayout = .sourceFolders
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)
        model.mediaFileNameFilterQuery = "take"
        model.addCurrentMediaCopyWorkflowToQueue()

        model.mediaCopySourceRoots = [secondSource]
        model.mediaCopyDestinationRoot = destination
        model.mediaCopyDestinationLayout = .mergeContents
        model.mediaCopyFilter = .audio
        model.setMediaCopyExtension("aiff", enabled: true)
        model.mediaFileNameFilterQuery = ""
        model.addCurrentMediaCopyWorkflowToQueue()

        XCTAssertEqual(model.mediaCopyQueue.count, 2)
        XCTAssertTrue(model.canSaveMediaCopyQueueAsWorkflow)

        MediaCopyAppKitBoundary.savedWorkflowNameProvider = { "  Rehearsal Stems  " }
        model.saveMediaCopyQueueAsWorkflow()

        XCTAssertEqual(model.mediaCopySavedWorkflows.count, 1)
        let savedItem = try XCTUnwrap(model.mediaCopySavedWorkflows.first)
        XCTAssertEqual(savedItem.name, "Rehearsal Stems")
        XCTAssertEqual(savedItem.workflows.map(\.id), model.mediaCopyQueue.map(\.id))
        XCTAssertEqual(savedItem.workflows.map(\.sourceRoots), model.mediaCopyQueue.map(\.sourceRoots))
        XCTAssertEqual(
            savedItem.workflows.map(\.destinationRoot),
            model.mediaCopyQueue.map(\.destinationRoot)
        )
        XCTAssertEqual(
            savedItem.workflows.map(\.destinationLayout),
            model.mediaCopyQueue.map(\.destinationLayout)
        )
        XCTAssertEqual(savedItem.workflows.map(\.filter), model.mediaCopyQueue.map(\.filter))
        XCTAssertEqual(
            savedItem.workflows.map(\.selectedExtensions),
            model.mediaCopyQueue.map(\.selectedExtensions)
        )
        XCTAssertEqual(
            savedItem.workflows.map(\.fileNameFilter),
            model.mediaCopyQueue.map(\.fileNameFilter)
        )
        XCTAssertEqual(model.selectedMediaCopySavedWorkflowID, savedItem.id)

        let queuedWorkflows = model.mediaCopyQueue
        let libraryURL = MediaCopySavedWorkflowLibrary(directoryURL: libraryStorageRoot).documentURL
        let lastSessionURL = MediaCopyQueueStore(directoryURL: queueStorageRoot).documentURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lastSessionURL.path))
        XCTAssertNotEqual(
            libraryURL.path,
            lastSessionURL.path,
            "The named library file must be a different document from the last-session queue file."
        )
        XCTAssertNotEqual(
            MediaCopySavedWorkflowLibrary.documentName,
            MediaCopyQueueStore.documentName
        )
        XCTAssertEqual(lastSessionURL.lastPathComponent, "MediaCopyQueue.json")

        let reloaded = makeModel(
            queueStorageRoot: queueStorageRoot,
            libraryStorageRoot: libraryStorageRoot
        )
        XCTAssertEqual(reloaded.mediaCopySavedWorkflows.count, 1)
        let reloadedItem = try XCTUnwrap(reloaded.mediaCopySavedWorkflows.first)
        XCTAssertEqual(reloadedItem.id, savedItem.id)
        XCTAssertEqual(reloadedItem.name, "Rehearsal Stems")
        XCTAssertEqual(reloadedItem.workflows.map(\.id), queuedWorkflows.map(\.id))
        XCTAssertEqual(
            reloadedItem.workflows.map(\.sourceRoots),
            queuedWorkflows.map(\.sourceRoots)
        )
        XCTAssertEqual(
            reloadedItem.workflows.map(\.destinationRoot),
            queuedWorkflows.map(\.destinationRoot)
        )
        XCTAssertEqual(
            reloadedItem.workflows.map(\.destinationLayout),
            queuedWorkflows.map(\.destinationLayout)
        )
        XCTAssertEqual(reloadedItem.workflows.map(\.filter), queuedWorkflows.map(\.filter))
        XCTAssertEqual(
            reloadedItem.workflows.map(\.selectedExtensions),
            queuedWorkflows.map(\.selectedExtensions)
        )
        XCTAssertEqual(
            reloadedItem.workflows.map(\.fileNameFilter),
            queuedWorkflows.map(\.fileNameFilter)
        )
        assertCreatedAtSurvivesDocumentPrecision(
            reloadedItem.workflows,
            expected: queuedWorkflows
        )
        XCTAssertEqual(reloadedItem.workflows, canonicalWorkflows(queuedWorkflows))

        XCTAssertFalse(reloaded.isMediaCopyBusy)
        XCTAssertFalse(reloaded.isMediaCopyScanning)
        XCTAssertFalse(reloaded.isMediaCopying)
        XCTAssertNil(reloaded.mediaCopyPlan)
        XCTAssertNil(reloaded.mediaCopyProgress)
        XCTAssertNil(reloaded.currentMediaCopyWorkflowID)
        XCTAssertEqual(
            try treeFingerprint(of: destination),
            destinationFingerprintBefore,
            "Saving or restoring a named library must not start a copy."
        )
    }

    // MARK: - Load replaces the working queue through the existing path

    func testLoadingNamedItemReplacesWorkingQueueAndNeverStartsACopy() throws {
        let workspace = try makeTemporaryDirectory()
        let queueStorageRoot = try makeDirectory("QueueStorage", in: workspace)
        let libraryStorageRoot = try makeDirectory("LibraryStorage", in: workspace)
        let source = try makeDirectory("Source", in: workspace)
        try writeFile("Audio/take.wav", in: source, contents: "take")
        let destination = try makeDirectory("Destination", in: workspace)
        let otherSource = try makeDirectory("OtherSource", in: workspace)
        let destinationFingerprintBefore = try treeFingerprint(of: destination)

        let model = makeModel(
            queueStorageRoot: queueStorageRoot,
            libraryStorageRoot: libraryStorageRoot
        )
        try enqueueWorkflow(source: source, destination: destination, in: model)
        let savedWorkflows = model.mediaCopyQueue
        MediaCopyAppKitBoundary.savedWorkflowNameProvider = { "Show Archive" }
        model.saveMediaCopyQueueAsWorkflow()
        let savedID = try XCTUnwrap(model.mediaCopySavedWorkflows.first?.id)

        try enqueueWorkflow(source: otherSource, destination: destination, in: model)
        XCTAssertEqual(model.mediaCopyQueue.count, 2)

        model.selectedMediaCopySavedWorkflowID = savedID
        XCTAssertTrue(model.canLoadMediaCopySavedWorkflow)
        model.loadMediaCopySavedWorkflow()

        XCTAssertEqual(model.mediaCopyQueue.map(\.id), savedWorkflows.map(\.id))
        XCTAssertEqual(model.mediaCopyQueue, savedWorkflows)
        XCTAssertTrue(model.mediaCopyQueue.allSatisfy { $0.repairIssues.isEmpty })
        XCTAssertTrue(model.canRunMediaCopyQueue)
        XCTAssertFalse(model.isMediaCopyBusy)
        XCTAssertNil(model.currentMediaCopyWorkflowID)
        XCTAssertNil(model.mediaCopyPlan)
        XCTAssertNil(model.mediaCopyProgress)
        XCTAssertEqual(
            try treeFingerprint(of: destination),
            destinationFingerprintBefore,
            "Load must not create destination files."
        )
        XCTAssertTrue(
            model.statusMessage.contains("Loaded 1 file copy workflow"),
            "Load must publish the existing replace-queue status sentence, got: \(model.statusMessage)"
        )

        model.clearMediaCopyQueue()
        XCTAssertTrue(model.mediaCopyQueue.isEmpty)

        let reloaded = makeModel(
            queueStorageRoot: queueStorageRoot,
            libraryStorageRoot: libraryStorageRoot
        )
        reloaded.selectedMediaCopySavedWorkflowID = savedID
        reloaded.loadMediaCopySavedWorkflow()
        XCTAssertEqual(reloaded.mediaCopyQueue.map(\.id), savedWorkflows.map(\.id))
        XCTAssertEqual(
            reloaded.mediaCopyQueue.map(\.sourceRoots),
            savedWorkflows.map(\.sourceRoots)
        )
        XCTAssertFalse(reloaded.isMediaCopyBusy)
        XCTAssertNil(reloaded.currentMediaCopyWorkflowID)
        XCTAssertTrue(reloaded.canRunMediaCopyQueue)
    }

    func testLoadingNamedItemWithMissingFoldersSurfacesNeedsRepairAndRefusesRun() throws {
        let workspace = try makeTemporaryDirectory()
        let queueStorageRoot = try makeDirectory("QueueStorage", in: workspace)
        let libraryStorageRoot = try makeDirectory("LibraryStorage", in: workspace)
        let vanishingSource = try makeDirectory("VanishingSource", in: workspace)
        try writeFile("Audio/take.wav", in: vanishingSource, contents: "take")
        let destination = try makeDirectory("Destination", in: workspace)

        let model = makeModel(
            queueStorageRoot: queueStorageRoot,
            libraryStorageRoot: libraryStorageRoot
        )
        try enqueueWorkflow(source: vanishingSource, destination: destination, in: model)
        MediaCopyAppKitBoundary.savedWorkflowNameProvider = { "Broken Folders" }
        model.saveMediaCopyQueueAsWorkflow()
        let savedID = try XCTUnwrap(model.mediaCopySavedWorkflows.first?.id)

        try FileManager.default.removeItem(at: vanishingSource)
        model.clearMediaCopyQueue()
        model.selectedMediaCopySavedWorkflowID = savedID
        model.loadMediaCopySavedWorkflow()

        XCTAssertEqual(model.mediaCopyQueue.count, 1)
        XCTAssertFalse(model.mediaCopyQueue[0].repairIssues.isEmpty)
        XCTAssertEqual(model.mediaCopyQueueRepairCount, 1)
        XCTAssertFalse(model.canRunMediaCopyQueue)
        XCTAssertTrue(
            model.statusMessage.contains("need") && model.statusMessage.contains("repair"),
            "Missing folders must surface the existing repair-aware status sentence, got: \(model.statusMessage)"
        )
        XCTAssertFalse(model.isMediaCopyBusy)
        XCTAssertNil(model.currentMediaCopyWorkflowID)
    }

    // MARK: - Overwrite same name; different name adds; blanks are rejected

    func testSavingSameTrimmedNameOverwritesInPlaceAndBlankNamesDoNotWrite() throws {
        let workspace = try makeTemporaryDirectory()
        let queueStorageRoot = try makeDirectory("QueueStorage", in: workspace)
        let libraryStorageRoot = try makeDirectory("LibraryStorage", in: workspace)
        let firstSource = try makeDirectory("FirstSource", in: workspace)
        let secondSource = try makeDirectory("SecondSource", in: workspace)
        let thirdSource = try makeDirectory("ThirdSource", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let library = MediaCopySavedWorkflowLibrary(directoryURL: libraryStorageRoot)

        let model = makeModel(
            queueStorageRoot: queueStorageRoot,
            libraryStorageRoot: libraryStorageRoot
        )
        try enqueueWorkflow(source: firstSource, destination: destination, in: model)
        let firstWorkflows = model.mediaCopyQueue
        MediaCopyAppKitBoundary.savedWorkflowNameProvider = { "Rehearsal Stems" }
        model.saveMediaCopyQueueAsWorkflow()
        let originalID = try XCTUnwrap(model.mediaCopySavedWorkflows.first?.id)
        let libraryBytesAfterFirstSave = try Data(contentsOf: library.documentURL)

        MediaCopyAppKitBoundary.savedWorkflowNameProvider = { "   " }
        model.saveMediaCopyQueueAsWorkflow()
        XCTAssertEqual(model.mediaCopySavedWorkflows.count, 1)
        XCTAssertEqual(model.mediaCopySavedWorkflows.first?.id, originalID)
        XCTAssertEqual(model.mediaCopySavedWorkflows.first?.name, "Rehearsal Stems")
        XCTAssertEqual(
            try Data(contentsOf: library.documentURL),
            libraryBytesAfterFirstSave,
            "A rejected name must not write the library."
        )

        MediaCopyAppKitBoundary.savedWorkflowNameProvider = { "" }
        model.saveMediaCopyQueueAsWorkflow()
        XCTAssertEqual(model.mediaCopySavedWorkflows.map(\.id), [originalID])
        XCTAssertEqual(
            try Data(contentsOf: library.documentURL),
            libraryBytesAfterFirstSave
        )

        model.clearMediaCopyQueue()
        try enqueueWorkflow(source: secondSource, destination: destination, in: model)
        let overwrittenWorkflows = model.mediaCopyQueue
        MediaCopyAppKitBoundary.savedWorkflowNameProvider = { "  Rehearsal Stems  " }
        model.saveMediaCopyQueueAsWorkflow()

        XCTAssertEqual(model.mediaCopySavedWorkflows.count, 1)
        XCTAssertEqual(model.mediaCopySavedWorkflows.first?.id, originalID)
        XCTAssertEqual(
            model.mediaCopySavedWorkflows.first?.workflows.map(\.id),
            overwrittenWorkflows.map(\.id)
        )
        XCTAssertNotEqual(
            model.mediaCopySavedWorkflows.first?.workflows.map(\.id),
            firstWorkflows.map(\.id)
        )

        try enqueueWorkflow(source: thirdSource, destination: destination, in: model)
        MediaCopyAppKitBoundary.savedWorkflowNameProvider = { "Show Archive" }
        model.saveMediaCopyQueueAsWorkflow()
        XCTAssertEqual(model.mediaCopySavedWorkflows.count, 2)
        XCTAssertEqual(
            Set(model.mediaCopySavedWorkflows.map(\.name)),
            Set(["Rehearsal Stems", "Show Archive"])
        )
        XCTAssertEqual(
            model.mediaCopySavedWorkflows.filter { $0.name == "Rehearsal Stems" }.count,
            1,
            "Overwrite must not create a duplicate name."
        )

        let reloaded = makeModel(
            queueStorageRoot: queueStorageRoot,
            libraryStorageRoot: libraryStorageRoot
        )
        XCTAssertEqual(reloaded.mediaCopySavedWorkflows.count, 2)
        let reloadedOriginal = try XCTUnwrap(
            reloaded.mediaCopySavedWorkflows.first { $0.name == "Rehearsal Stems" }
        )
        XCTAssertEqual(reloadedOriginal.id, originalID)
        XCTAssertEqual(
            reloadedOriginal.workflows.map(\.id),
            overwrittenWorkflows.map(\.id)
        )
        XCTAssertEqual(
            Set(reloaded.mediaCopySavedWorkflows.map(\.name)),
            Set(["Rehearsal Stems", "Show Archive"])
        )
    }

    // MARK: - Delete persist

    func testDeletingNamedItemRemovesItFromFreshModelAndLeavesWorkingQueue() throws {
        let workspace = try makeTemporaryDirectory()
        let queueStorageRoot = try makeDirectory("QueueStorage", in: workspace)
        let libraryStorageRoot = try makeDirectory("LibraryStorage", in: workspace)
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)

        let model = makeModel(
            queueStorageRoot: queueStorageRoot,
            libraryStorageRoot: libraryStorageRoot
        )
        try enqueueWorkflow(source: source, destination: destination, in: model)
        let queuedWorkflows = model.mediaCopyQueue
        MediaCopyAppKitBoundary.savedWorkflowNameProvider = { "Show Archive" }
        model.saveMediaCopyQueueAsWorkflow()
        XCTAssertEqual(model.mediaCopySavedWorkflows.count, 1)

        MediaCopyAppKitBoundary.deleteSavedWorkflowConfirmProvider = { name in
            XCTAssertEqual(name, "Show Archive")
            return true
        }
        XCTAssertTrue(model.canDeleteMediaCopySavedWorkflow)
        model.deleteMediaCopySavedWorkflow()

        XCTAssertTrue(model.mediaCopySavedWorkflows.isEmpty)
        XCTAssertNil(model.selectedMediaCopySavedWorkflowID)
        XCTAssertEqual(model.mediaCopyQueue.map(\.id), queuedWorkflows.map(\.id))
        XCTAssertFalse(model.isMediaCopyBusy)
        XCTAssertNil(model.currentMediaCopyWorkflowID)

        let reloaded = makeModel(
            queueStorageRoot: queueStorageRoot,
            libraryStorageRoot: libraryStorageRoot
        )
        XCTAssertTrue(
            reloaded.mediaCopySavedWorkflows.isEmpty,
            "A deleted named item must not appear in a freshly composed model."
        )
        XCTAssertEqual(
            reloaded.mediaCopyQueue.map(\.id),
            queuedWorkflows.map(\.id),
            "Delete must not clear the last-session working queue."
        )
        XCTAssertFalse(reloaded.isMediaCopyBusy)
    }

    // MARK: - Last-session persist stays a separate document

    func testLastSessionPersistStaysSeparateAndFinderJobIdentitiesRemain() throws {
        let workspace = try makeTemporaryDirectory()
        let queueStorageRoot = try makeDirectory("QueueStorage", in: workspace)
        let libraryStorageRoot = try makeDirectory("LibraryStorage", in: workspace)
        let isolatedLibraryRoot = try makeDirectory("IsolatedLibrary", in: workspace)
        let originalSource = try makeDirectory("OriginalSource", in: workspace)
        let savedSource = try makeDirectory("SavedSource", in: workspace)
        try writeFile("Audio/take.wav", in: savedSource, contents: "take")
        let loadedSource = try makeDirectory("LoadedSource", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)

        let model = makeModel(
            queueStorageRoot: queueStorageRoot,
            libraryStorageRoot: libraryStorageRoot
        )
        try enqueueWorkflow(source: originalSource, destination: destination, in: model)
        try enqueueWorkflow(source: savedSource, destination: destination, in: model)
        XCTAssertEqual(model.mediaCopyQueue.count, 2)
        let savedWorkflows = Array(model.mediaCopyQueue.suffix(1))
        model.removeMediaCopyWorkflowFromQueue(model.mediaCopyQueue[0])
        XCTAssertEqual(model.mediaCopyQueue.map(\.id), savedWorkflows.map(\.id))

        MediaCopyAppKitBoundary.savedWorkflowNameProvider = { "Show Archive" }
        model.saveMediaCopyQueueAsWorkflow()
        model.clearMediaCopyQueue()
        model.selectedMediaCopySavedWorkflowID = model.mediaCopySavedWorkflows.first?.id
        model.loadMediaCopySavedWorkflow()
        XCTAssertEqual(model.mediaCopyQueue.map(\.id), savedWorkflows.map(\.id))

        let libraryURL = MediaCopySavedWorkflowLibrary(directoryURL: libraryStorageRoot).documentURL
        let lastSessionURL = MediaCopyQueueStore(directoryURL: queueStorageRoot).documentURL
        XCTAssertNotEqual(libraryURL.path, lastSessionURL.path)
        XCTAssertEqual(lastSessionURL.lastPathComponent, "MediaCopyQueue.json")
        XCTAssertNotEqual(libraryURL.lastPathComponent, lastSessionURL.lastPathComponent)

        let lastSessionOnly = makeModel(
            queueStorageRoot: queueStorageRoot,
            libraryStorageRoot: isolatedLibraryRoot
        )
        XCTAssertEqual(
            lastSessionOnly.mediaCopyQueue.map(\.id),
            savedWorkflows.map(\.id),
            "A fresh model that only mounts the last-session queue directory must restore that working queue."
        )
        XCTAssertTrue(
            lastSessionOnly.mediaCopySavedWorkflows.isEmpty,
            "Mounting only the last-session directory must not read the named library."
        )

        XCTAssertEqual(MediaCopyJobDocument.currentVersion, 2)
        XCTAssertEqual(MediaCopyJobFile.fileExtension, "job")
        let finderSave = MediaCopyAppKitBoundary.chooseSaveJobURL
        let finderLoad = MediaCopyAppKitBoundary.chooseLoadJobURL
        XCTAssertNotNil(finderSave)
        XCTAssertNotNil(finderLoad)

        let replacementWorkflow = MediaCopyWorkflow(
            sourceRoots: [loadedSource],
            destinationRoot: destination,
            destinationLayout: .mergeContents,
            filter: .audio,
            selectedExtensions: ["wav"],
            fileNameFilter: MediaFileNameFilter(query: "take"),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jobData = try encoder.encode(MediaCopyJobDocument(workflows: [replacementWorkflow]))
        try model.loadMediaCopyJobData(jobData)
        XCTAssertEqual(model.mediaCopyQueue.map(\.id), [replacementWorkflow.id])
        XCTAssertEqual(model.mediaCopyQueue, [replacementWorkflow])
    }

    // MARK: - Corruption and future-version gates

    func testCorruptLibraryDocumentYieldsEmptyLibraryQuarantineAndUnchangedQueue() throws {
        let workspace = try makeTemporaryDirectory()
        let queueStorageRoot = try makeDirectory("QueueStorage", in: workspace)
        let libraryStorageRoot = try makeDirectory("LibraryStorage", in: workspace)
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)

        let seed = makeModel(
            queueStorageRoot: queueStorageRoot,
            libraryStorageRoot: libraryStorageRoot
        )
        try enqueueWorkflow(source: source, destination: destination, in: seed)
        XCTAssertEqual(seed.mediaCopyQueue.count, 1)
        let seededQueue = seed.mediaCopyQueue

        let library = MediaCopySavedWorkflowLibrary(directoryURL: libraryStorageRoot)
        try FileManager.default.createDirectory(
            at: libraryStorageRoot,
            withIntermediateDirectories: true
        )
        let corruptBytes = Data("{ this is not a saved-workflow library ".utf8)
        try corruptBytes.write(to: library.documentURL)

        let model = makeModel(
            queueStorageRoot: queueStorageRoot,
            libraryStorageRoot: libraryStorageRoot
        )
        XCTAssertTrue(
            model.mediaCopySavedWorkflows.isEmpty,
            "A corrupt library document must yield an empty library."
        )
        XCTAssertEqual(
            model.mediaCopyQueue.map(\.id),
            seededQueue.map(\.id),
            "A failed library decode must not replace the last-session working queue."
        )
        XCTAssertTrue(
            model.statusMessage.contains("repair"),
            "A corrupt library document must report a repairable status, got: \(model.statusMessage)"
        )

        let quarantineSidecars = try quarantineSidecars(in: libraryStorageRoot)
        XCTAssertEqual(quarantineSidecars.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(quarantineSidecars.first)),
            corruptBytes,
            "The quarantined sidecar must preserve the original corrupt bytes."
        )
        XCTAssertFalse(model.isMediaCopyBusy)
        XCTAssertNil(model.currentMediaCopyWorkflowID)
    }

    func testFutureVersionLibraryDocumentIsRejectedAndWorkingQueueStays() throws {
        let workspace = try makeTemporaryDirectory()
        let queueStorageRoot = try makeDirectory("QueueStorage", in: workspace)
        let libraryStorageRoot = try makeDirectory("LibraryStorage", in: workspace)
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)

        let seed = makeModel(
            queueStorageRoot: queueStorageRoot,
            libraryStorageRoot: libraryStorageRoot
        )
        try enqueueWorkflow(source: source, destination: destination, in: seed)
        let seededQueue = seed.mediaCopyQueue

        let library = MediaCopySavedWorkflowLibrary(directoryURL: libraryStorageRoot)
        try FileManager.default.createDirectory(
            at: libraryStorageRoot,
            withIntermediateDirectories: true
        )
        let futureVersionBytes = Data(
            """
            {"version":\(MediaCopySavedWorkflowLibraryDocument.currentVersion + 1),\
            "savedAt":"2026-01-01T00:00:00Z","items":[]}
            """.utf8
        )
        try futureVersionBytes.write(to: library.documentURL)

        let model = makeModel(
            queueStorageRoot: queueStorageRoot,
            libraryStorageRoot: libraryStorageRoot
        )
        XCTAssertTrue(model.mediaCopySavedWorkflows.isEmpty)
        XCTAssertEqual(model.mediaCopyQueue.map(\.id), seededQueue.map(\.id))
        XCTAssertTrue(
            model.statusMessage.contains("repair"),
            "A future-version library document must report a repairable status, got: \(model.statusMessage)"
        )

        let quarantineSidecars = try quarantineSidecars(in: libraryStorageRoot)
        XCTAssertEqual(quarantineSidecars.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(quarantineSidecars.first)),
            futureVersionBytes
        )
        XCTAssertFalse(model.isMediaCopyBusy)
    }

    // MARK: - Helpers

    private static let defaultSavedWorkflowNameProvider: () -> String? = {
        MediaCopyAppKitBoundary.promptSavedWorkflowName()
    }

    private static let defaultDeleteSavedWorkflowConfirmProvider: (String) -> Bool = { name in
        MediaCopyAppKitBoundary.confirmDeleteSavedWorkflow(named: name)
    }

    private static let defaultRepairDirectoryProvider: (URL) -> URL? = { missingURL in
        MediaCopyAppKitBoundary.chooseRepairDirectory(for: missingURL)
    }

    private func canonicalWorkflows(_ workflows: [MediaCopyWorkflow]) -> [MediaCopyWorkflow] {
        workflows.map { workflow in
            var workflow = workflow
            workflow.createdAt = Date(
                timeIntervalSince1970: workflow.createdAt.timeIntervalSince1970.rounded(.down)
            )
            return workflow
        }
    }

    private func assertCreatedAtSurvivesDocumentPrecision(
        _ actual: [MediaCopyWorkflow],
        expected: [MediaCopyWorkflow],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (actualWorkflow, expectedWorkflow) in zip(actual, expected) {
            XCTAssertLessThan(
                abs(actualWorkflow.createdAt.timeIntervalSince(expectedWorkflow.createdAt)),
                1,
                "createdAt must survive persistence at document precision.",
                file: file,
                line: line
            )
        }
    }

    private func makeModel(queueStorageRoot: URL, libraryStorageRoot: URL) -> EncoderViewModel {
        let model = EncoderViewModel(
            mediaCopyQueueStorageRoot: queueStorageRoot,
            mediaCopySavedWorkflowLibraryStorageRoot: libraryStorageRoot
        )
        model.completionNotificationsEnabled = false
        model.fileManagementMode = .copy
        return model
    }

    private func enqueueWorkflow(
        source: URL,
        destination: URL,
        in model: EncoderViewModel
    ) throws {
        model.mediaCopySourceRoots = [source]
        model.mediaCopyDestinationRoot = destination
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)
        model.mediaFileNameFilterQuery = ""
        model.addCurrentMediaCopyWorkflowToQueue()
    }

    private func quarantineSidecars(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "corrupt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func treeFingerprint(of directory: URL) throws -> [String: String] {
        var fingerprint: [String: String] = [:]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        )
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else { continue }
            let relativePath = url.path.hasPrefix(directory.path + "/")
                ? String(url.path.dropFirst(directory.path.count + 1))
                : url.path
            fingerprint[relativePath] = try String(contentsOf: url, encoding: .utf8)
        }
        return fingerprint
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPhilCoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }

    private func makeDirectory(_ path: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeFile(_ path: String, in root: URL, contents: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
