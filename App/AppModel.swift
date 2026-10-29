import SwiftUI
import Photos
import os.log

import VampireIndex
import CullIntent
import BurstClustering
import SonyMakerNotes

let log = Logger(subsystem: "app.vampire", category: "app")

/// Root state. The app is organized around culling sessions: a user-selected
/// subset of the library — or a camera card over Wi-Fi — with its own intent
/// journal and burst groups. Both kinds cull through the same UI; only where
/// pixels come from (`imageProvider`) and what Apply does differ.
/// Indexing only ever runs over the *open* session's assets — never the whole
/// library. The per-asset index is shared across sessions so nothing is
/// extracted twice. UI-facing mutations happen on the main actor; indexing
/// streams in behind (hard constraint 7).
@MainActor
@Observable
final class AppModel {
    private(set) var authorizationStatus: PHAuthorizationStatus

    // MARK: Session list (home screen)
    private(set) var sessionSummaries: [SessionSummary] = []

    // MARK: Open session state
    private(set) var currentSession: CullSessionRecord?
    /// Session photos, newest first.
    private(set) var items: [CullItem] = []
    private(set) var burstGroups: [BurstGroup] = []
    /// Pager structure: one entry per burst group (or singleton), outer and
    /// inner both newest-first. Horizontal = between groups, vertical =
    /// within a burst.
    private(set) var groupedItems: [[CullItem]] = []
    /// Bumped when images become available that weren't before (camera
    /// frames landing in the cache) so grid/pager re-request them.
    private(set) var imageRevision = 0

    var isCameraSession: Bool { currentSession?.kind == .camera }
    /// assetID → indexed record, streamed in by the indexer.
    private(set) var index: [String: AssetIndexRecord] = [:]
    private(set) var indexingProgress: (done: Int, total: Int) = (0, 0)
    private(set) var intentLog = IntentLog()

    let store: IndexStore?
    let imageManager = PHCachingImageManager()
    @ObservationIgnored private(set) lazy var libraryImages = LibraryImageProvider(imageManager: imageManager)
    @ObservationIgnored private(set) lazy var cameraImages = CameraImageProvider(camera: camera)
    /// Pixels for the open session.
    var imageProvider: CullImageProvider { isCameraSession ? cameraImages : libraryImages }
    let camera = CameraSessionModel.shared
    private var indexer: Indexer?
    private var reclusterTask: Task<Void, Never>?

    /// IntentLog is a plain class — SwiftUI can't observe it. Every mutation
    /// goes through refreshVerdictState(), which mirrors the queryable bits
    /// into these observable properties. Views must read these, never the
    /// log directly, or they won't update.
    private(set) var verdictRevision = 0
    private(set) var verdictCounts: [Verdict: Int] = [:]
    private(set) var canUndo = false
    private(set) var canRedo = false

    private func refreshVerdictState() {
        verdictCounts = intentLog.counts
        canUndo = intentLog.canUndo
        canRedo = intentLog.canRedo
        verdictRevision += 1
    }

    init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        // Store lives in Application Support; losing it only means re-indexing.
        let storeURL = URL.applicationSupportDirectory.appending(path: "vampire-index.sqlite")
        try? FileManager.default.createDirectory(
            at: .applicationSupportDirectory, withIntermediateDirectories: true
        )
        do {
            store = try IndexStore(path: storeURL.path)
        } catch {
            log.error("index store unavailable, sessions cannot persist: \(error)")
            store = nil
        }
        refreshSessionList()
        wireCamera()
    }

    func requestAuthorization() async {
        authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: - Session lifecycle

    func refreshSessionList() {
        sessionSummaries = (try? store?.sessionSummaries()) ?? []
    }

    /// Creates a session from picker-selected asset IDs and opens it.
    func createSession(name: String, assetIDs: [String]) {
        guard let store, !assetIDs.isEmpty else { return }
        do {
            let session = try store.createSession(name: name, assetIDs: assetIDs)
            refreshSessionList()
            openSession(session)
        } catch {
            log.error("failed to create session: \(error)")
        }
    }

    func openSession(_ session: CullSessionRecord) {
        guard let store else { return }
        closeSession()

        currentSession = session
        try? store.markSessionOpened(id: session.id)
        let memberIDs = (try? store.assetIDs(inSession: session.id)) ?? []
        let known = (try? store.allAssets()) ?? []
        let knownByID = Dictionary(known.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })

        var liveIDs: Set<String>
        switch session.kind {
        case .library:
            let result = PHAsset.fetchAssets(withLocalIdentifiers: memberIDs, options: nil)
            var fetched: [CullItem] = []
            fetched.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in fetched.append(CullItem(asset: asset)) }
            items = fetched
            // Assets that vanished from the library since last time (deleted
            // elsewhere) drop out of the session.
            liveIDs = Set(fetched.map(\.id))
            let goneIDs = memberIDs.filter { !liveIDs.contains($0) }
            if !goneIDs.isEmpty {
                try? store.removeAssets(goneIDs, fromSession: session.id)
            }
        case .camera:
            // Shots live on the card; the index rows (written when each was
            // first cached) carry their capture times. Pixels come back as
            // the camera reconnects.
            items = memberIDs.map { CullItem(cameraID: $0, creationDate: knownByID[$0]?.creationDate) }
            liveIDs = Set(memberIDs)
        }
        // Newest first.
        items.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }

        intentLog = (try? store.makeIntentLog(forSession: session.id)) ?? IntentLog()
        refreshVerdictState()

        index = knownByID.filter { liveIDs.contains($0.key) }
        recluster()
        switch session.kind {
        case .library: startIndexing()
        case .camera: cameraSessionOpened()
        }
    }

    /// Stops all session work. Indexing never runs while no session is open.
    func closeSession() {
        indexer?.cancel()
        indexer = nil
        reclusterTask?.cancel()
        reclusterTask = nil
        currentSession = nil
        items = []
        index = [:]
        burstGroups = []
        groupedItems = []
        intentLog = IntentLog()
        indexingProgress = (0, 0)
        imageManager.stopCachingImagesForAllAssets()
        cameraImages.stopCachingAll()
        refreshSessionList()
    }

    func deleteSession(_ summary: SessionSummary) {
        try? store?.deleteSession(id: summary.id)
        refreshSessionList()
    }

    func renameSession(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? store?.renameSession(id: id, name: trimmed)
        if currentSession?.id == id {
            currentSession?.name = trimmed
        }
        refreshSessionList()
    }

    /// Adds picker-selected assets to the open session and reloads it in
    /// place (indexing restarts; already-indexed assets are skipped).
    func addAssetsToCurrentSession(_ assetIDs: [String]) {
        guard let store, let session = currentSession, !assetIDs.isEmpty else { return }
        try? store.addAssets(assetIDs, toSession: session.id)
        openSession(session)
    }

    // MARK: - Indexing (open session only)

    private func startIndexing() {
        guard let store, currentSession != nil else { return }
        let indexer = Indexer(store: store, imageManager: imageManager)
        self.indexer = indexer
        let toIndex = items.compactMap(\.asset)

        Task { [weak self] in
            await indexer.run(assets: toIndex) { [weak self] update in
                Task { @MainActor [weak self] in
                    self?.apply(update)
                }
            }
        }
    }

    private func apply(_ update: IndexUpdate) {
        switch update {
        case .progress(let done, let total):
            indexingProgress = (done, total)
        case .indexed(let record, _):
            index[record.assetID] = record
            scheduleRecluster()
        }
    }

    // MARK: - Clustering (per session)

    /// Re-sorts time clusters with whatever feature prints exist so far.
    private func scheduleRecluster() {
        guard reclusterTask == nil else { return }
        reclusterTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1)) // debounce streaming updates
            guard let self, !Task.isCancelled else { return }
            self.reclusterTask = nil
            self.recluster()
        }
    }

    private func recluster() {
        guard let session = currentSession else { return }
        let clusterables = items.compactMap { item -> ClusterableAsset? in
            guard let date = item.creationDate else { return nil }
            return ClusterableAsset(
                id: item.id,
                creationDate: date,
                featurePrint: index[item.id]?.featurePrint
            )
        }
        // A burst is a CHAIN: consecutive frames under 1s apart, however long
        // the chain runs (a 10fps drive held for 8s is one burst). Purely
        // temporal for the pager stacks — visual split/merge would stack
        // photos that aren't bursts (similar shots 30s apart) or break real
        // drives on a scene change, both surprising as navigation.
        burstGroups = BurstClusterer.cluster(
            clusterables,
            parameters: ClusteringParameters(
                timeGapThreshold: 1.0,
                splitDistance: .infinity,
                mergeDistance: 0,
                mergeMaxTimeGap: 0
            )
        )
        rebuildGroupedItems()

        if let store {
            var assignments: [String: String?] = [:]
            for group in burstGroups where group.count > 1 {
                for id in group.assetIDs { assignments[id] = group.id }
            }
            let sessionID = session.id
            Task.detached(priority: .utility) {
                try? store.assignBurstGroups(assignments, inSession: sessionID)
            }
        }
    }

    /// Collapses the flat newest-first list into pager groups: burst
    /// members stack together at the position of their newest frame.
    private func rebuildGroupedItems() {
        let itemByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var groupForItem: [String: BurstGroup] = [:]
        for group in burstGroups where group.count > 1 {
            for id in group.assetIDs { groupForItem[id] = group }
        }

        var seenGroupIDs = Set<String>()
        var result: [[CullItem]] = []
        for item in items {
            if let group = groupForItem[item.id] {
                guard seenGroupIDs.insert(group.id).inserted else { continue }
                let members = group.assetIDs
                    .compactMap { itemByID[$0] }
                    .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
                result.append(members)
            } else {
                result.append([item])
            }
        }
        groupedItems = result
    }

    // MARK: - Culling

    func setVerdict(_ verdict: Verdict?, for item: CullItem) {
        intentLog.set(verdict, for: item.id)
        refreshVerdictState()
    }

    func verdict(for item: CullItem) -> Verdict? {
        intentLog.verdict(for: item.id)
    }

    /// Returns the affected assetID so the rating UI can bring its card back.
    @discardableResult
    func undo() -> String? {
        let assetID = intentLog.undo()
        refreshVerdictState()
        return assetID
    }

    @discardableResult
    func redo() -> String? {
        let assetID = intentLog.redo()
        refreshVerdictState()
        return assetID
    }

    /// What an Apply did — drives the results screen.
    struct ApplyResult: Identifiable, Sendable {
        let id = UUID()
        let sessionName: String
        let keepCount: Int
        let rejectCount: Int
        /// Bytes of the kept / deleted originals; nil when sizes were
        /// unavailable. Deleted bytes free up after Recently Deleted expires.
        let keepBytes: Int64?
        let rejectBytes: Int64?
    }

    /// Commits the open session: one batched change, one system dialog.
    func apply(dryRun: Bool = false) async throws -> ApplyResult {
        // Camera sessions never delete: their Apply is importKeepers().
        guard let session = currentSession, session.kind == .library else {
            throw ApplyEngine.ApplyError.nothingToApply
        }
        let rejects = Array(intentLog.assetIDs(with: .reject))
        let keeps = Array(intentLog.assetIDs(with: .keep))
        // Sizes must be read BEFORE the deletion.
        let rejectBytes = Self.totalResourceBytes(forAssetIDs: rejects)
        let keepBytes = Self.totalResourceBytes(forAssetIDs: keeps)

        let summary = try await ApplyEngine().apply(rejects: rejects, keeps: keeps, dryRun: dryRun)
        if !dryRun {
            // Applied decisions now live in the Photos library; the rejects
            // are gone from it, so drop them from the session and index too.
            try? store?.clearIntentLog(forSession: session.id)
            try? store?.removeAssets(rejects, fromSession: session.id)
            try? store?.deleteAssets(ids: rejects)
            openSession(session)
        }
        return ApplyResult(
            sessionName: session.name,
            keepCount: summary.keepCount,
            rejectCount: summary.rejectCount,
            keepBytes: keepBytes,
            rejectBytes: rejectBytes
        )
    }

    /// Sum of original-resource sizes. PHAssetResource has no public size
    /// accessor; the well-known "fileSize" key works — degrade to nil if not.
    private static func totalResourceBytes(forAssetIDs ids: [String]) -> Int64? {
        guard !ids.isEmpty else { return 0 }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var total: Int64 = 0
        var anyFound = false
        result.enumerateObjects { asset, _, _ in
            for resource in PHAssetResource.assetResources(for: asset) {
                if let size = resource.value(forKey: "fileSize") as? Int64 {
                    total += size
                    anyFound = true
                }
            }
        }
        return anyFound ? total : nil
    }

    // MARK: - Camera sessions

    /// Opens the camera session (one camera, one session) and connects.
    /// It persists across reconnects and days: each connect adds new shots
    /// and keeps every decision, so a multi-day trip can be culled a night
    /// at a time while the card stays the backup. Shots deleted from the
    /// card drop out of the app (see `cameraListed`).
    func openCameraSession() {
        guard let store else { return }
        let existing = (try? store.allSessions())?.first { $0.kind == .camera }
        let session = existing ?? (try? store.createSession(name: "Camera card", assetIDs: [], kind: .camera))
        guard let session else { return }
        refreshSessionList()
        openSession(session)
    }

    private func cameraSessionOpened() {
        if camera.isConnected {
            cameraListed(camera.photos)  // already connected: adopt the card now
        } else if camera.phase != .connecting {
            camera.findAndConnect()
        }
    }

    /// Imports the session's keepers (full RAWs) into Photos. Additive only.
    func importKeepers() {
        guard isCameraSession else { return }
        camera.importKeepers()
    }

    private func wireCamera() {
        camera.onPhotosListed = { [weak self] photos in self?.cameraListed(photos) }
        camera.onFrameCached = { [weak self] photo, record, faces in
            self?.cameraFrameCached(photo, record: record, faces: faces)
        }
        camera.onImagesChanged = { [weak self] in self?.imageRevision += 1 }
        camera.needsAnalysis = { [weak self] id in
            (self?.index[id]?.indexVersion ?? 0) < IndexStore.currentIndexVersion
        }
        camera.keeperIDs = { [weak self] in
            guard let self, self.isCameraSession else { return [] }
            return self.intentLog.assetIDs(with: .keep)
        }
    }

    /// Card listing arrived — the card is the truth. New shots join the
    /// session with a stub index row (capture time, size) so they sort and
    /// cluster at once. Shots no longer on the card leave the app entirely:
    /// membership, decisions, index row, faces, imported marker — state
    /// shouldn't pile up forever. Exception: a card that reads completely
    /// empty prunes nothing (a busy/removed/misread card looks the same);
    /// a reformatted card with new shots on it does clear the old ones.
    private func cameraListed(_ photos: [CameraPhoto]) {
        guard let store, let session = currentSession, session.kind == .camera else { return }
        let onCard = Set(photos.map(\.indexID))
        let known = Set(items.map(\.id))

        let gone = known.subtracting(onCard)
        if !gone.isEmpty {
            if onCard.isEmpty {
                camera.record("card reads empty — keeping \(gone.count) photos until it shows shots again")
            } else {
                let ids = Array(gone)
                try? store.removeAssets(ids, fromSession: session.id)
                try? store.removeIntents(forAssets: ids, inSession: session.id)
                try? store.deleteAssets(ids: ids)
                camera.forgetImported(ids)
                for id in ids { index[id] = nil }
                items.removeAll { gone.contains($0.id) }
                intentLog = (try? store.makeIntentLog(forSession: session.id)) ?? IntentLog()
                refreshVerdictState()
                camera.record("dropped \(ids.count) photos no longer on the card")
            }
        }

        let fresh = photos.filter { !known.contains($0.indexID) }
        if !fresh.isEmpty {
            try? store.addAssets(fresh.map(\.indexID), toSession: session.id)
            for photo in fresh where index[photo.indexID] == nil {
                let stub = AssetIndexRecord(assetID: photo.indexID, creationDate: photo.capturedAt,
                                            pixelWidth: photo.pixelWidth, pixelHeight: photo.pixelHeight,
                                            isRAW: photo.isRAW)
                try? store.upsert(stub)
                index[photo.indexID] = stub
            }
            items += fresh.map { CullItem(cameraID: $0.indexID, creationDate: $0.capturedAt) }
            items.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        }
        guard !fresh.isEmpty || !gone.isEmpty else { return }
        recluster()
        refreshSessionList()
    }

    private func cameraFrameCached(_ photo: CameraPhoto, record: AssetIndexRecord?, faces: [FaceRecord]) {
        if isCameraSession { indexingProgress = (camera.cachedCount, camera.photos.count) }
        guard let record, let store else { return }
        try? store.upsert(record)
        try? store.replaceFaces(faces, forAsset: record.assetID)
        guard isCameraSession else { return }
        index[record.assetID] = record
        scheduleRecluster()
    }
}
