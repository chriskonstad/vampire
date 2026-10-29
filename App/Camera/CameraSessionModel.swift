import SwiftUI
import UIKit

import PTP
import SonyMakerNotes
import VampireIndex

/// The camera side of a camera culling session: connect to the A7RV over
/// PTP/IP, list the card, prefetch every frame's thumbnail + upright preview
/// into the session cache (indexing each one exactly like the library
/// indexer), and import keepers.
///
/// Culling itself — journal, bursts, HUD, grid, pager — is the shared
/// session UI in AppModel; this model feeds it through the hooks below.
/// Culling never depends on the live connection: once a frame is cached it
/// stays cullable if the camera drops (sleep, range, power). Only Import needs
/// the camera, and it reconnects first. Process-lifetime singleton.
@MainActor
@Observable
final class CameraSessionModel {
    static let shared = CameraSessionModel()

    enum Phase: Equatable {
        case disconnected
        case connecting
        case connected(cameraName: String)
        case failed(String)
    }

    private(set) var phase: Phase = .disconnected
    private(set) var photos: [CameraPhoto] = []
    private var photosByIndexID: [String: CameraPhoto] = [:]
    private(set) var thumbnails: [String: UIImage] = [:]
    /// indexID → upright preview in the session cache.
    private(set) var previews: [String: URL] = [:]
    private(set) var importProgress: (done: Int, total: Int)?
    /// Fraction of the RAW currently streaming (0...1).
    private(set) var importFileFraction: Double = 0
    /// True while an import is paused waiting for the camera to come back.
    private(set) var importWaitingForCamera = false
    private(set) var lastImportSummary: String?
    /// True while the link is down and the model is trying to get it back.
    private(set) var isReconnecting = false
    /// indexIDs already imported to Photos — persisted so a relaunch never
    /// imports a keeper twice.
    private(set) var imported: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "camera.imported") ?? []) {
        didSet { UserDefaults.standard.set(Array(imported), forKey: "camera.imported") }
    }

    var isConnected: Bool { if case .connected = phase { true } else { false } }
    var cachedCount: Int { previews.count }

    // MARK: Hooks into the shared culling session (set by AppModel)

    /// The card listing changed (connect / reconnect / new shots).
    @ObservationIgnored var onPhotosListed: (([CameraPhoto]) -> Void)?
    /// A frame landed in the cache; record/faces are nil when it was already
    /// indexed in an earlier run (pixels re-fetched, Vision skipped).
    @ObservationIgnored var onFrameCached: ((CameraPhoto, AssetIndexRecord?, [FaceRecord]) -> Void)?
    /// Thumbnails or previews became available — views should re-ask.
    @ObservationIgnored var onImagesChanged: (() -> Void)?
    /// Whether an indexID still needs the Vision/MakerNotes pass.
    @ObservationIgnored var needsAnalysis: ((String) -> Bool)?
    /// Current keepers (indexIDs), read live so ones marked mid-import join.
    @ObservationIgnored var keeperIDs: (() -> Set<String>)?

    var pendingImports: [CameraPhoto] {
        let keeps = keeperIDs?() ?? []
        return photos.filter { keeps.contains($0.indexID) && !imported.contains($0.indexID) }
    }

    func photo(forIndexID id: String) -> CameraPhoto? { photosByIndexID[id] }
    func thumbnail(forIndexID id: String) -> UIImage? { thumbnails[id] }
    func previewURL(forIndexID id: String) -> URL? { previews[id] }

    private var client: SonyCameraClient?
    /// Identifies the live client so a late drop signal from an old one
    /// can't knock down its replacement.
    private var clientToken = UUID()
    private var prefetchTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    /// The user asked to be connected (vs. explicitly disconnected): drives
    /// auto-reconnect.
    private var wantsLink = false
    private let cache = CameraFrameCache.shared

    /// Last camera address. Default is Sony's own Wi-Fi Direct gateway.
    var cameraIP: String = UserDefaults.standard.string(forKey: "camera.ip") ?? "192.168.122.1" {
        didSet { UserDefaults.standard.set(cameraIP, forKey: "camera.ip") }
    }

    private init() {}

    // MARK: - Diagnostics

    /// Connection diagnostics, newest last. Shown on screen (copyable) and
    /// appended to Documents/camera-log.txt for pulling off the device.
    private(set) var logLines: [String] = []
    var logText: String { logLines.joined(separator: "\n") }

    func record(_ line: String) {
        let stamped = "\(Date().formatted(.dateTime.hour().minute().second())) \(line)"
        logLines.append(stamped)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
        log.info("camera: \(line, privacy: .public)")
        Self.appendToFile(stamped)
    }

    nonisolated private static func appendToFile(_ line: String) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("camera-log.txt")
        let bytes = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: url)
        }
    }

    /// Sendable logger for the actors; hops to the main actor.
    private var logSink: PTPTransport.Log {
        { [weak self] line in Task { @MainActor in self?.record(line) } }
    }

    private var guid: Data {
        let key = "ptp.guid"
        if let existing = UserDefaults.standard.data(forKey: key), existing.count == 16 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        let data = Data(bytes)
        UserDefaults.standard.set(data, forKey: key)
        return data
    }

    // MARK: - Connect / browse

    /// Connects (or reconnects) and merges the card listing into the session.
    /// Existing photos, cache and decisions survive — a reconnect just adds
    /// new shots and resumes prefetching.
    @discardableResult
    func connect() -> Task<Bool, Never> {
        if case .connecting = phase, let pending = connectTask { return pending }
        phase = .connecting
        record("— connect to \(cameraIP) —")
        prefetchTask?.cancel()
        let old = client
        client = nil
        let ip = cameraIP
        wantsLink = true
        let task = Task { () -> Bool in
            await old?.disconnect()
            // A camera that just lost a session (phone slept, Wi-Fi blipped)
            // refuses new ones for a few seconds — retry before giving up.
            for attempt in 1 ... 3 {
                let token = UUID()
                let client = SonyCameraClient(
                    host: ip, guid: self.guid, log: self.logSink,
                    onDisconnect: { [weak self] in
                        Task { @MainActor in self?.linkDropped(token: token) }
                    })
                do {
                    try await client.connect()
                    let name = await client.cameraName
                    let list = try await client.listImages()
                    self.client = client
                    self.clientToken = token
                    self.phase = .connected(cameraName: name.isEmpty ? ip : name)
                    self.merge(list)
                    self.startPrefetch()
                    return true
                } catch {
                    await client.disconnect()
                    self.record("attempt \(attempt) failed: \(error)")
                    if attempt < 3, Self.isConnectionLoss(error) {
                        try? await Task.sleep(for: .seconds(2))
                        continue
                    }
                    self.phase = .failed("\(error)")
                    return false
                }
            }
            return false
        }
        connectTask = task
        return task
    }

    private var connectTask: Task<Bool, Never>?

    /// True while scanning the Wi-Fi for the camera.
    private(set) var isSearching = false

    /// Getting onto the camera's own Wi-Fi without Settings (AccessorySetupKit).
    @ObservationIgnored private(set) lazy var link = CameraLink(log: { [weak self] in self?.record($0) })

    /// One plain-language line on why the last Connect didn't get there
    /// (nil when fine). Replaces stacked transport/join errors in the UI.
    private(set) var connectProblem: String?

    /// The one Connect. The camera is (almost) always on its own Wi-Fi
    /// Direct network in the field, so that comes first:
    ///
    /// - Camera network saved → on it already, or join it → connect.
    /// - None saved, from a tap (`interactive`) → camera Wi-Fi picker →
    ///   one-time password → join → connect.
    /// - The current (e.g. home) Wi-Fi is searched only by
    ///   `searchThisNetwork()`, or quietly when nothing is saved and this
    ///   isn't a tap (session open / auto-reconnect never pop UI).
    @discardableResult
    func findAndConnect(interactive: Bool = true) -> Task<Bool, Never> {
        isSearching = true
        connectProblem = nil
        record("connecting to the camera…")
        return Task {
            defer { isSearching = false }
            var onCameraNetwork = false
            if link.hasSavedCamera {
                onCameraNetwork = await link.joinSavedCameraIfNeeded()
            } else if interactive {
                record("no camera Wi-Fi saved — showing the camera Wi-Fi picker")
                onCameraNetwork = await link.pickAndJoin()
            }
            if onCameraNetwork {
                // On Wi-Fi Direct the camera is the gateway; the finder
                // tries that (and the last address) first.
                return await finishConnect(found: await CameraFinder.find(preferred: cameraIP, log: logSink),
                                           notFound: "Joined the camera's Wi-Fi, but the camera didn't answer. Is Remote Shooting on?")
            }
            if !interactive, !link.hasSavedCamera {
                return await finishConnect(found: await CameraFinder.find(preferred: cameraIP, log: logSink),
                                           notFound: "Camera not found. Tap Connect to join its Wi-Fi.")
            }
            connectProblem = linkProblem
                ?? "Couldn't reach the camera's Wi-Fi. Is the camera on, with Remote Shooting set to Wi-Fi Direct?"
            phase = .failed(connectProblem ?? "")
            return false
        }
    }

    /// For a camera on a shared network (home Wi-Fi, Access Point mode):
    /// search the phone's current Wi-Fi instead of the camera's own.
    @discardableResult
    func searchThisNetwork() -> Task<Bool, Never> {
        isSearching = true
        connectProblem = nil
        record("searching this Wi-Fi for the camera…")
        return Task {
            defer { isSearching = false }
            return await finishConnect(found: await CameraFinder.find(preferred: cameraIP, log: logSink),
                                       notFound: "No camera on this Wi-Fi.")
        }
    }

    private var linkProblem: String? {
        if case .failed(let message) = link.state { return message }
        return nil
    }

    private func finishConnect(found: String?, notFound: String) async -> Bool {
        guard let found else {
            record("no camera found")
            connectProblem = notFound
            phase = .failed(connectProblem ?? "")
            return false
        }
        record("found camera at \(found)")
        cameraIP = found
        let ok = await connect().value
        if !ok { connectProblem = "Found the camera, but it refused the connection — accept the prompt on the camera." }
        return ok
    }

    func disconnect() {
        wantsLink = false
        reconnectTask?.cancel()
        prefetchTask?.cancel()
        let client = self.client
        self.client = nil
        phase = .disconnected
        Task { await client?.disconnect() }
    }

    /// Called when the app returns to the foreground: the socket usually died
    /// while asleep, so quietly reconnect if there's work left.
    func resumeIfNeeded() {
        guard wantsLink, phase != .connecting else { return }
        if !isConnected || cachedCount < photos.count {
            record("foreground: reconnecting")
            connect()
        }
    }

    /// The card listing is the truth: adopt it wholesale (new shots in,
    /// removed shots out, along with their cached pixels).
    private func merge(_ list: [CameraPhoto]) {
        let known = Set(photos.map(\.indexID))
        let onCard = Set(list.map(\.indexID))
        let fresh = list.filter { !known.contains($0.indexID) }
        let gone = known.subtracting(onCard)
        photos = list.sorted { $0.createdUTCms < $1.createdUTCms }
        photosByIndexID = Dictionary(photos.map { ($0.indexID, $0) }, uniquingKeysWith: { a, _ in a })
        for id in gone {
            thumbnails[id] = nil
            if let url = previews.removeValue(forKey: id) { try? FileManager.default.removeItem(at: url) }
        }
        record("\(list.count) on card, \(fresh.count) new, \(gone.count) gone")
        onPhotosListed?(photos)
    }

    /// Shots that left the card no longer need an imported marker.
    func forgetImported(_ ids: some Sequence<String>) {
        imported.subtract(ids)
    }

    /// The connection died mid-operation: keep everything cached, drop to
    /// offline so the UI says so, and let the user (or foregrounding) retry.
    /// The old session is closed for real — a half-open one keeps the camera
    /// "remotely operating" and makes it refuse the reconnect.
    private func lostConnection(_ error: Error) {
        guard isConnected else { return }
        record("connection lost: \(error) — culling continues from cache")
        prefetchTask?.cancel()
        let dead = client
        client = nil
        phase = .disconnected
        Task { await dead?.disconnect() }
        startAutoReconnect()
    }

    /// The transport noticed the link die on its own (keepalive, camera off)
    /// while nothing was in flight.
    private func linkDropped(token: UUID) {
        guard token == clientToken else { return }
        lostConnection(PTPTransport.TransportError.notConnected)
    }

    /// Keeps trying to get the camera back while the user wants a link —
    /// so switching the camera back on just works, and a paused import
    /// resumes by itself.
    private func startAutoReconnect() {
        guard wantsLink, reconnectTask == nil else { return }
        isReconnecting = true
        reconnectTask = Task {
            defer { isReconnecting = false; reconnectTask = nil }
            var failures = 0
            while wantsLink, !isConnected, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard wantsLink, !isConnected, !Task.isCancelled else { break }
                if case .connecting = phase { continue }
                // Every third miss, rescan: on home Wi-Fi the camera may come
                // back on a different DHCP address.
                let ok = failures % 3 == 2 ? await findAndConnect(interactive: false).value : await connect().value
                if ok { record("camera is back") } else { failures += 1 }
            }
        }
    }

    /// Whether an error means the link is gone, as opposed to the camera
    /// refusing a single operation (skip that frame, keep going).
    private static func isConnectionLoss(_ error: Error) -> Bool {
        if let transport = error as? PTPTransport.TransportError { return transport.isConnectionLoss }
        return error is PTPWireError  // a malformed frame desyncs the stream
    }

    // MARK: - Prefetch into the session cache

    /// Thumbnails for everything first (cheap, fills the grid), then full
    /// cull frames in capture order, prioritizing whatever the user opened.
    private func startPrefetch() {
        prefetchTask?.cancel()
        guard let client else { return }
        prefetchTask = Task {
            for photo in photos where thumbnails[photo.indexID] == nil {
                guard !Task.isCancelled else { return }
                do {
                    let data = try await client.thumbnail(for: photo)
                    if let image = UIImage(data: data) {
                        thumbnails[photo.indexID] = image
                        onImagesChanged?()
                    }
                } catch where Self.isConnectionLoss(error) {
                    lostConnection(error); return
                } catch {
                    record("thumbnail \(photo.filename) failed: \(error)")
                }
            }
            var failed = Set<String>()
            while !Task.isCancelled {
                let needed = { (p: CameraPhoto) in self.previews[p.indexID] == nil && !failed.contains(p.indexID) }
                guard let next = priority.first(where: needed) ?? photos.first(where: needed) else { break }
                do {
                    try await fetchFrame(next, client: client)
                } catch where Self.isConnectionLoss(error) {
                    lostConnection(error); return
                } catch {
                    // One bad frame must not end the session; retried on the
                    // next connect.
                    record("skipping \(next.filename) for now: \(error)")
                    failed.insert(next.indexID)
                }
            }
            if !Task.isCancelled { record("all \(photos.count) frames cached — safe to disconnect") }
        }
    }

    /// Photos the user is looking at; prefetch serves these first.
    private var priority: [CameraPhoto] = []

    /// The pager is showing this shot: fetch it (and the next few) first.
    func prioritize(indexID: String) {
        guard let index = photos.firstIndex(where: { $0.indexID == indexID }) else { return }
        priority = Array(photos[index ..< min(index + 4, photos.count)])
    }

    private func fetchFrame(_ photo: CameraPhoto, client: SonyCameraClient) async throws {
        let start = ContinuousClock.now
        let analyze = needsAnalysis?(photo.indexID) ?? true
        let preview = try await client.cullPreview(for: photo, includeHead: analyze)
        let cache = self.cache
        let processed = try await Task.detached(priority: .userInitiated) {
            try cache.process(photo, screennail: preview.image, metadata: preview.metadata, analyze: analyze)
        }.value
        previews[photo.indexID] = processed.previewURL
        onFrameCached?(photo, processed.record, processed.faces)
        onImagesChanged?()
        let elapsed = ContinuousClock.now - start
        let detail = processed.record.map {
            "AF \($0.focusLocation == nil ? "–" : "✓"), \($0.faceCount) faces, \($0.cameraModel ?? "no model")"
        } ?? "already indexed"
        record("cached \(photo.filename) \(preview.image.count / 1024)KB, \(detail), "
            + elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))
    }

    // MARK: - Import keepers

    /// Imports kept originals into Photos. Resumable: if the camera drops
    /// mid-import, it waits for the link (auto-reconnect) and picks up with
    /// the next unimported keeper — keepers marked meanwhile join the queue.
    /// Additive only: rejects are never touched on the card.
    func importKeepers() {
        guard importTask == nil, !pendingImports.isEmpty else { return }
        wantsLink = true
        var done = 0
        var doneBytes: Int64 = 0
        var skipped = Set<String>()
        // Survive backgrounding and the Lock Screen: a continued-processing
        // task (system Live Activity with progress + cancel). If the system
        // won't grant one, fall back to keeping the screen awake so
        // auto-lock can't suspend the app mid-RAW. Either way the import
        // resumes at the byte it stopped if it is interrupted.
        let count = pendingImports.count
        let work = ContinuedWork(title: "Importing \(count) keeper\(count == 1 ? "" : "s")",
                                 subtitle: "From your camera, full RAWs") { [weak self] in
            self?.record("import stopped from the Live Activity / by the system")
            self?.importTask?.cancel()
        }
        if !work.isContinued { UIApplication.shared.isIdleTimerDisabled = true }
        importTask = Task {
            var succeeded = false
            defer {
                importTask = nil
                importProgress = nil
                importWaitingForCamera = false
                UIApplication.shared.isIdleTimerDisabled = false
                work.finish(success: succeeded)
            }
            while !Task.isCancelled {
                let queue = pendingImports.filter { !skipped.contains($0.indexID) }
                guard let photo = queue.first else { succeeded = true; break }
                importProgress = (done, done + queue.count)
                let totalBytes = doneBytes + queue.reduce(Int64(0)) { $0 + Int64($1.sizeBytes) }
                guard isConnected, let client else {
                    work.update(completed: doneBytes, total: totalBytes, subtitle: "Waiting for the camera…")
                    importWaitingForCamera = true
                    if !isConnected, reconnectTask == nil, phase != .connecting { startAutoReconnect() }
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                importWaitingForCamera = false
                // Stable partial-file path per photo: an interrupted transfer
                // resumes from what's already on disk.
                let tmp = Self.partialImportURL(for: photo)
                do {
                    let start = ContinuousClock.now
                    importFileFraction = 0
                    let total = Double(max(photo.sizeBytes, 1))
                    let subtitle = "\(done + 1) of \(done + queue.count) · \(photo.filename)"
                    let base = doneBytes
                    work.update(completed: base, total: totalBytes, subtitle: subtitle)
                    try await client.download(photo, to: tmp) { bytes in
                        Task { @MainActor in
                            self.importFileFraction = Double(bytes) / total
                            work.update(completed: base + Int64(bytes), total: totalBytes)
                        }
                    }
                    try await CameraImporter.importToPhotos(fileURL: tmp, filename: photo.filename)
                    imported.insert(photo.indexID)
                    done += 1
                    doneBytes += Int64(photo.sizeBytes)
                    record("imported \(photo.filename) in "
                        + (ContinuousClock.now - start).formatted(.units(allowed: [.seconds], width: .narrow)))
                } catch {
                    record("import \(photo.filename) failed: \(error)")
                    if Self.isConnectionLoss(error) {
                        // Keep the partial file; the loop waits for the
                        // camera, then resumes this photo where it stopped.
                        lostConnection(error)
                    } else {
                        try? FileManager.default.removeItem(at: tmp)
                        skipped.insert(photo.indexID)
                    }
                }
            }
            let failed = skipped.count
            lastImportSummary = "Imported \(done) keeper\(done == 1 ? "" : "s") to Photos"
                + (failed > 0 ? ", \(failed) failed (see log)" : "")
                + ". Nothing was deleted from the card."
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    /// Partial RAWs live in tmp (wiped by iOS as needed, and by us per photo
    /// once imported — PhotoKit moves the finished file in).
    private static func partialImportURL(for photo: CameraPhoto) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("camera-imports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(photo.slot)-\(photo.contentID)-\(photo.filename)")
    }
}
