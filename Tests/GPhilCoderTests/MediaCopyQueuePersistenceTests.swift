import Foundation
import GPhilCoderCore
import XCTest
@testable import GPhilCoder

/// Frozen final-gate suite for ticket 001: the file-copy workflow queue must
/// survive quitting and relaunching without any manual action.
///
/// Every row drives the real composition root (`EncoderViewModel`, the object
/// the UI binds) against a test-controlled storage root, mutates the queue
/// through the entry points the UI calls, and then composes a fresh model from
/// the same storage root to assert the reloaded state.
@MainActor
final class MediaCopyQueuePersistenceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        clearViewModelDefaultsForTests()
    }

    override func tearDownWithError() throws {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        clearViewModelDefaultsForTests()
        try super.tearDownWithError()
    }

    // MARK: - Queue mutations persist; a fresh composition restores them

    func testQueueMutationsPersistAndFreshModelRestoresIdenticalQueue() throws {
        let workspace = try makeTemporaryDirectory()
        let storageRoot = try makeDirectory("QueueStorage", in: workspace)
        let firstSource = try makeDirectory("FirstSource", in: workspace)
        try writeFile("Audio/take01.wav", in: firstSource, contents: "take one")
        let secondSource = try makeDirectory("SecondSource", in: workspace)
        try writeFile("Audio/take02.aiff", in: secondSource, contents: "take two")
        try writeFile("Video/take03.mov", in: secondSource, contents: "take three")
        let destination = try makeDirectory("Destination", in: workspace)

        let model = makeModel(queueStorageRoot: storageRoot)
        model.mediaCopySourceRoots = [firstSource]
        model.mediaCopyDestinationRoot = destination
        model.mediaCopyFilter = .audio
        model.deselectAllMediaCopyExtensions()
        model.setMediaCopyExtension("wav", enabled: true)
        model.mediaFileNameFilterQuery = "take"

        model.addCurrentMediaCopyWorkflowToQueue()
        XCTAssertEqual(model.mediaCopyQueue.count, 1)

        model.mediaCopySourceRoots = [secondSource]
        model.mediaCopyDestinationRoot = destination
        model.mediaCopyFilter = .audio
        model.setMediaCopyExtension("aiff", enabled: true)
        model.mediaFileNameFilterQuery = ""

        model.addCurrentMediaCopyWorkflowToQueue()
        XCTAssertEqual(model.mediaCopyQueue.count, 2)

        let queuedWorkflows = model.mediaCopyQueue
        XCTAssertEqual(queuedWorkflows[0].sourceRoots, [firstSource])
        XCTAssertEqual(queuedWorkflows[0].selectedExtensions, Set(["wav"]))
        XCTAssertEqual(queuedWorkflows[0].fileNameFilter.query, "take")
        XCTAssertEqual(queuedWorkflows[1].sourceRoots, [secondSource])

        let documentData = try Data(
            contentsOf: MediaCopyQueueStore(directoryURL: storageRoot).documentURL
        )
        let documentJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: documentData) as? [String: Any]
        )
        XCTAssertEqual(documentJSON["version"] as? Int, MediaCopyJobDocument.currentVersion)

        let reloaded = makeModel(queueStorageRoot: storageRoot)
        XCTAssertEqual(reloaded.mediaCopyQueue.count, 2)
        XCTAssertEqual(reloaded.mediaCopyQueue.map(\.id), queuedWorkflows.map(\.id))
        XCTAssertEqual(
            reloaded.mediaCopyQueue.map(\.sourceRoots),
            queuedWorkflows.map(\.sourceRoots)
        )
        XCTAssertEqual(
            reloaded.mediaCopyQueue.map(\.destinationRoot),
            queuedWorkflows.map(\.destinationRoot)
        )
        XCTAssertEqual(
            reloaded.mediaCopyQueue.map(\.destinationLayout),
            queuedWorkflows.map(\.destinationLayout)
        )
        XCTAssertEqual(
            reloaded.mediaCopyQueue.map(\.filter),
            queuedWorkflows.map(\.filter)
        )
        XCTAssertEqual(
            reloaded.mediaCopyQueue.map(\.selectedExtensions),
            queuedWorkflows.map(\.selectedExtensions)
        )
        XCTAssertEqual(
            reloaded.mediaCopyQueue.map(\.fileNameFilter),
            queuedWorkflows.map(\.fileNameFilter)
        )
        // The shared MediaCopyJobDocument format stores dates as ISO-8601 with
        // second precision (the same semantics as manual .job Save/Load), so
        // createdAt round-trips to the same second.
        for (reloadedWorkflow, queuedWorkflow) in zip(reloaded.mediaCopyQueue, queuedWorkflows) {
            XCTAssertLessThan(
                abs(reloadedWorkflow.createdAt.timeIntervalSince(queuedWorkflow.createdAt)),
                1,
                "createdAt must survive the relaunch at document precision."
            )
        }
        XCTAssertEqual(reloaded.mediaCopyQueue, canonicalQueue(queuedWorkflows))
    }

    func testRemoveWorkflowFromQueuePersistsWithoutResurrection() throws {
        let workspace = try makeTemporaryDirectory()
        let storageRoot = try makeDirectory("QueueStorage", in: workspace)
        let firstSource = try makeDirectory("FirstSource", in: workspace)
        let secondSource = try makeDirectory("SecondSource", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)

        let model = makeModel(queueStorageRoot: storageRoot)
        try enqueueWorkflow(source: firstSource, destination: destination, in: model)
        try enqueueWorkflow(source: secondSource, destination: destination, in: model)
        XCTAssertEqual(model.mediaCopyQueue.count, 2)

        let removedID = try XCTUnwrap(model.mediaCopyQueue.first?.id)
        let remaining = try XCTUnwrap(model.mediaCopyQueue.last)

        model.removeMediaCopyWorkflowFromQueue(model.mediaCopyQueue[0])

        XCTAssertEqual(model.mediaCopyQueue.map(\.id), [remaining.id])

        let reloaded = makeModel(queueStorageRoot: storageRoot)
        XCTAssertEqual(reloaded.mediaCopyQueue.map(\.id), [remaining.id])
        XCTAssertFalse(
            reloaded.mediaCopyQueue.contains { $0.id == removedID },
            "A removed workflow must not resurrect after relaunch."
        )
    }

    func testClearMediaCopyQueuePersistsWithoutResurrection() throws {
        let workspace = try makeTemporaryDirectory()
        let storageRoot = try makeDirectory("QueueStorage", in: workspace)
        let firstSource = try makeDirectory("FirstSource", in: workspace)
        let secondSource = try makeDirectory("SecondSource", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)

        let model = makeModel(queueStorageRoot: storageRoot)
        try enqueueWorkflow(source: firstSource, destination: destination, in: model)
        try enqueueWorkflow(source: secondSource, destination: destination, in: model)
        XCTAssertEqual(model.mediaCopyQueue.count, 2)

        model.clearMediaCopyQueue()

        XCTAssertTrue(model.mediaCopyQueue.isEmpty)

        let reloaded = makeModel(queueStorageRoot: storageRoot)
        XCTAssertTrue(
            reloaded.mediaCopyQueue.isEmpty,
            "A cleared queue must stay cleared across relaunch."
        )
    }

    // MARK: - NEEDS REPAIR restore and relink

    func testRestoredWorkflowWithMissingFolderNeedsRepairAndRelinkPersists() throws {
        let workspace = try makeTemporaryDirectory()
        let storageRoot = try makeDirectory("QueueStorage", in: workspace)
        let vanishingSource = try makeDirectory("VanishingSource", in: workspace)
        try writeFile("Audio/take.wav", in: vanishingSource, contents: "take")
        let destination = try makeDirectory("Destination", in: workspace)

        let model = makeModel(queueStorageRoot: storageRoot)
        try enqueueWorkflow(source: vanishingSource, destination: destination, in: model)
        XCTAssertEqual(model.mediaCopyQueue.count, 1)
        XCTAssertEqual(model.mediaCopyQueueRepairCount, 0)

        // The source folder disappears before relaunch (rename, unmount, SMB drop).
        try FileManager.default.removeItem(at: vanishingSource)

        let reloaded = makeModel(queueStorageRoot: storageRoot)
        XCTAssertEqual(reloaded.mediaCopyQueue.count, 1)
        let restoredWorkflow = try XCTUnwrap(reloaded.mediaCopyQueue.first)
        XCTAssertFalse(
            restoredWorkflow.repairIssues.isEmpty,
            "A restored workflow whose folder vanished must surface NEEDS REPAIR."
        )
        XCTAssertEqual(reloaded.mediaCopyQueueRepairCount, 1)
        XCTAssertFalse(
            reloaded.canRunMediaCopyQueue,
            "A queue with repair issues must refuse to run."
        )
        XCTAssertEqual(restoredWorkflow.repairIssues.first?.url, vanishingSource)

        // Relink the restored workflow at the queue seam (the Repair panel is
        // AppKit-only); the persistence hook must record the repaired roots.
        let replacementSource = try makeDirectory("ReplacementSource", in: workspace)
        reloaded.mediaCopyQueue = [
            restoredWorkflow.replacingSourceRoot(vanishingSource, with: replacementSource)
        ]
        XCTAssertEqual(reloaded.mediaCopyQueueRepairCount, 0)

        let relinkedModel = makeModel(queueStorageRoot: storageRoot)
        XCTAssertEqual(relinkedModel.mediaCopyQueue.count, 1)
        XCTAssertEqual(
            relinkedModel.mediaCopyQueue.first?.sourceRoots,
            [replacementSource]
        )
        XCTAssertEqual(relinkedModel.mediaCopyQueueRepairCount, 0)
    }

    // MARK: - Corruption and version gates

    func testCorruptPersistedDocumentIsQuarantinedAndQueueStartsEmpty() throws {
        let workspace = try makeTemporaryDirectory()
        let storageRoot = try makeDirectory("QueueStorage", in: workspace)
        let documentURL = MediaCopyQueueStore(directoryURL: storageRoot).documentURL
        let corruptBytes = Data("{ this is not a queue document ".utf8)
        try corruptBytes.write(to: documentURL)

        let model = makeModel(queueStorageRoot: storageRoot)

        XCTAssertTrue(
            model.mediaCopyQueue.isEmpty,
            "A corrupt persisted document must yield an empty queue."
        )
        XCTAssertFalse(
            model.statusMessage.isEmpty,
            "A corrupt persisted document must report a repairable status message."
        )

        let quarantineSidecars = try quarantineSidecars(in: storageRoot)
        XCTAssertEqual(quarantineSidecars.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(quarantineSidecars.first)),
            corruptBytes,
            "The quarantined sidecar must preserve the original corrupt bytes."
        )

        // The store stays usable: the next queue mutation persists normally.
        let source = try makeDirectory("RecoverySource", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        try enqueueWorkflow(source: source, destination: destination, in: model)
        XCTAssertEqual(model.mediaCopyQueue.count, 1)

        let recoveredData = try Data(contentsOf: documentURL)
        let recoveredJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: recoveredData) as? [String: Any]
        )
        let recoveredWorkflows = try XCTUnwrap(recoveredJSON["workflows"] as? [[String: Any]])
        XCTAssertEqual(recoveredWorkflows.count, 1)
    }

    func testFutureVersionDocumentIsRejectedAndQuarantined() throws {
        let workspace = try makeTemporaryDirectory()
        let storageRoot = try makeDirectory("QueueStorage", in: workspace)
        let documentURL = MediaCopyQueueStore(directoryURL: storageRoot).documentURL
        let futureVersionBytes = Data(
            """
            {"version":\(MediaCopyJobDocument.currentVersion + 1),\
            "savedAt":"2026-01-01T00:00:00Z","workflows":[]}
            """.utf8
        )
        try futureVersionBytes.write(to: documentURL)

        let model = makeModel(queueStorageRoot: storageRoot)

        XCTAssertTrue(
            model.mediaCopyQueue.isEmpty,
            "A future-version persisted document must yield an empty queue."
        )
        XCTAssertFalse(
            model.statusMessage.isEmpty,
            "A future-version persisted document must report a repairable status message."
        )

        let quarantineSidecars = try quarantineSidecars(in: storageRoot)
        XCTAssertEqual(quarantineSidecars.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(quarantineSidecars.first)),
            futureVersionBytes,
            "The quarantined sidecar must preserve the future-version bytes."
        )
    }

    func testFailedDecodeLeavesExistingQueueUnchangedOnLoadReplace() throws {
        let workspace = try makeTemporaryDirectory()
        let storageRoot = try makeDirectory("QueueStorage", in: workspace)
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)

        let model = makeModel(queueStorageRoot: storageRoot)
        try enqueueWorkflow(source: source, destination: destination, in: model)
        XCTAssertEqual(model.mediaCopyQueue.count, 1)

        // Snapshot the queue both as held in memory and as any fresh launch
        // sees it persisted, before the failing load-replace.
        let inMemoryQueueBefore = model.mediaCopyQueue
        let persistedQueueBefore = makeModel(queueStorageRoot: storageRoot).mediaCopyQueue
        XCTAssertEqual(persistedQueueBefore.count, 1)

        XCTAssertThrowsError(
            try model.loadMediaCopyJobData(Data("{}".utf8)),
            "A failed decode must reject the load instead of replacing the queue."
        )

        XCTAssertEqual(
            model.mediaCopyQueue,
            inMemoryQueueBefore,
            "Decode must complete before the in-memory queue is replaced."
        )

        let persistedQueueAfter = makeModel(queueStorageRoot: storageRoot).mediaCopyQueue
        XCTAssertEqual(
            persistedQueueAfter,
            persistedQueueBefore,
            "A failed load-replace must not touch the persisted queue."
        )
    }

    // MARK: - No auto-run on restore

    func testRestoreNeverRunsCopiesOrMarksWorkflowsActive() throws {
        let workspace = try makeTemporaryDirectory()
        let storageRoot = try makeDirectory("QueueStorage", in: workspace)
        let source = try makeDirectory("Source", in: workspace)
        try writeFile("Audio/take.wav", in: source, contents: "take")
        let destination = try makeDirectory("Destination", in: workspace)

        let model = makeModel(queueStorageRoot: storageRoot)
        try enqueueWorkflow(source: source, destination: destination, in: model)

        let sourceFingerprintBefore = try treeFingerprint(of: source)
        let destinationFingerprintBefore = try treeFingerprint(of: destination)

        let reloaded = makeModel(queueStorageRoot: storageRoot)

        XCTAssertEqual(reloaded.mediaCopyQueue.count, 1)
        XCTAssertFalse(reloaded.isMediaCopyScanning)
        XCTAssertFalse(reloaded.isMediaCopying)
        XCTAssertFalse(reloaded.isMediaCopyFinalizing)
        XCTAssertFalse(reloaded.isMediaDeleting)
        XCTAssertFalse(reloaded.isMediaRenaming)
        XCTAssertFalse(reloaded.isMediaCopyBusy)
        XCTAssertNil(reloaded.mediaCopyPlan)
        XCTAssertNil(reloaded.mediaCopyProgress)
        XCTAssertNil(reloaded.currentMediaCopyWorkflowID)

        XCTAssertEqual(
            try treeFingerprint(of: source),
            sourceFingerprintBefore,
            "Restoring the queue must not mutate the source tree."
        )
        XCTAssertEqual(
            try treeFingerprint(of: destination),
            destinationFingerprintBefore,
            "Restoring the queue must not mutate the destination tree."
        )
    }

    // MARK: - Store round trip (supplementary to the composition rows)

    func testStoreRoundTripPersistsVersionTwoDocument() throws {
        let workspace = try makeTemporaryDirectory()
        let storageRoot = try makeDirectory("QueueStorage", in: workspace)
        let source = try makeDirectory("Source", in: workspace)
        let destination = try makeDirectory("Destination", in: workspace)
        let store = MediaCopyQueueStore(directoryURL: storageRoot)

        XCTAssertEqual(store.load(), .noDocument)

        let workflow = MediaCopyWorkflow(
            sourceRoots: [source],
            destinationRoot: destination,
            destinationLayout: .mergeContents,
            filter: .audio,
            selectedExtensions: ["wav"],
            fileNameFilter: MediaFileNameFilter(query: "take"),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try store.save([workflow])

        let documentData = try Data(contentsOf: store.documentURL)
        let documentJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: documentData) as? [String: Any]
        )
        XCTAssertEqual(documentJSON["version"] as? Int, MediaCopyJobDocument.currentVersion)

        XCTAssertEqual(store.load(), .restored(workflows: [workflow]))

        try store.save([])
        XCTAssertEqual(store.load(), .restored(workflows: []))
    }

    // MARK: - Helpers

    /// A queue as the shared document format stores it: ISO-8601 dates carry
    /// second precision, so sub-second `createdAt` components do not survive
    /// persistence (the same semantics as manual .job Save/Load).
    private func canonicalQueue(_ workflows: [MediaCopyWorkflow]) -> [MediaCopyWorkflow] {
        workflows.map { workflow in
            var workflow = workflow
            workflow.createdAt = Date(
                timeIntervalSince1970: workflow.createdAt.timeIntervalSince1970.rounded(.down)
            )
            return workflow
        }
    }

    private func makeModel(queueStorageRoot: URL) -> EncoderViewModel {
        let model = EncoderViewModel(mediaCopyQueueStorageRoot: queueStorageRoot)
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

    /// Recursive snapshot of relative paths to file contents, for asserting
    /// that restore performs zero filesystem mutations.
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
