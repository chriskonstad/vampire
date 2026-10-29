import Foundation

import PTP
import SonyMakerNotes

/// One shot on the camera card, as seen over Sony remote transfer. Points at
/// the RAW file of a RAW+JPEG/HEIF pair when there is one.
struct CameraPhoto: Identifiable, Hashable, Sendable {
    let slot: UInt32
    let contentID: UInt32
    let fileID: UInt16
    let filename: String
    let sizeBytes: UInt64
    let isRAW: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let createdUTCms: UInt64
    /// In-camera star rating / protect — favorites marked while shooting.
    let rating: Int
    let isProtected: Bool

    struct ID: Hashable, Sendable { let slot: UInt32; let contentID: UInt32 }
    var id: ID { ID(slot: slot, contentID: contentID) }
    var capturedAt: Date { Date(timeIntervalSince1970: Double(createdUTCms) / 1000) }
}

/// High-level camera browsing + selective transfer over Sony's remote-transfer
/// ops (0x923B–0x923E): the camera UI stays usable while connected. The grid
/// gets Sony's 160×120 thumbnails, the pager its 1616×1080 screennail plus a
/// head read for the AF MakerNotes, and keepers stream their full RAW in
/// chunks. **Never deletes** — neither DeleteObject nor Sony's content delete
/// exists in the op set this client can send.
actor SonyCameraClient {
    private let transport: PTPTransport
    private let log: PTPTransport.Log
    private(set) var cameraName: String = ""
    private(set) var deviceInfo: PTPDeviceInfo?
    /// Enough head to read EXIF + Sony MakerNotes (AF point, faces).
    private let headProbeBytes: UInt32 = 256 * 1024
    private let downloadChunk: UInt32 = 4 * 1024 * 1024

    init(host: String, guid: Data, log: @escaping PTPTransport.Log,
         onDisconnect: @escaping @Sendable () -> Void = {}) {
        self.transport = PTPTransport(host: host, guid: guid, log: log, onDisconnect: onDisconnect)
        self.log = log
    }

    func connect() async throws {
        let ack = try await transport.connect()
        cameraName = ack.cameraName
        if let data = try? await transport.require(.getDeviceInfo, expectsData: true),
           let info = try? PTPDeviceInfo(from: data) {
            deviceInfo = info
            log("\(info.manufacturer) \(info.model) fw \(info.deviceVersion) · \(info.operations.count) ops")
        }
        // Session id is arbitrary but nonzero.
        _ = try await transport.require(.openSession, parameters: [1])
        // Sony's remote handshake (libgphoto2 / alpha2go sequence); unlocks
        // the vendor ops, including remote transfer.
        _ = try await transport.require(.sonySDIOConnect, parameters: [1, 0, 0], expectsData: true)
        _ = try await transport.require(.sonySDIOConnect, parameters: [2, 0, 0], expectsData: true)
        _ = try await transport.require(.sonyGetSDIOExtDeviceInfo, parameters: [0x12C, 1], expectsData: true)
        _ = try await transport.require(.sonySDIOConnect, parameters: [3, 0, 0], expectsData: true)
        if deviceInfo?.supports(.sonyGetContentsInfoList) == false {
            log("camera does not list remote-transfer ops — card browsing unavailable")
        }
    }

    func disconnect() async {
        _ = try? await transport.perform(.closeSession)
        await transport.close()
    }

    // MARK: - Browse

    /// Every still on both slots, oldest first (camera order).
    func listImages() async throws -> [CameraPhoto] {
        var photos: [CameraPhoto] = []
        for slot: UInt32 in [1, 2] {
            // The date list first: on an empty slot the contents list never
            // answers (alpha2go), while the date list says InvalidParameter.
            let (code, dates) = try await transport.perform(.sonyGetCapturedDateList, parameters: [slot])
            guard code == PTPResponse.ok.rawValue, let dates,
                  try SonyRemoteTransfer.capturedDateCount(dates) > 0 else {
                log("slot \(slot): empty or absent")
                continue
            }
            var cursor: UInt64 = 0
            var seen = Set<UInt32>()
            while true {
                let page = try SonyRemoteTransfer.parseContentsList(try await transport.require(
                    .sonyGetContentsInfoList,
                    parameters: SonyRemoteTransfer.contentsListParameters(cursor: cursor, slot: slot),
                    expectsData: true))
                for content in page where seen.insert(content.contentID).inserted {
                    if let photo = Self.photo(from: content, slot: slot) { photos.append(photo) }
                }
                guard page.count >= Int(SonyRemoteTransfer.pageSize),
                      let last = page.last?.createdUTCms, last != cursor else { break }
                cursor = last
            }
            log("slot \(slot): \(seen.count) shots")
        }
        return photos.sorted { $0.createdUTCms < $1.createdUTCms }
    }

    private static func photo(from content: SonyContent, slot: UInt32) -> CameraPhoto? {
        let stills = content.files.filter {
            [PTPObjectFormat.sonyRAW.rawValue, PTPObjectFormat.exifJPEG.rawValue, 0xB110].contains($0.format)
        }
        guard let file = stills.first(where: \.isRAW) ?? stills.first else { return nil }
        return CameraPhoto(slot: slot, contentID: content.contentID, fileID: file.fileID,
                           filename: file.filename, sizeBytes: file.size, isRAW: file.isRAW,
                           pixelWidth: Int(file.pixelWidth), pixelHeight: Int(file.pixelHeight),
                           createdUTCms: content.createdUTCms, rating: Int(content.rating),
                           isProtected: content.isProtected)
    }

    /// Sony's own small thumbnail (160×120 JPEG for RAW) for the grid.
    func thumbnail(for photo: CameraPhoto) async throws -> Data {
        try await compressed(photo, type: 1)
    }

    /// Everything the culling HUD needs for one frame, without the RAW: the
    /// 1616×1080 screennail plus MakerNotes parsed from a head read.
    struct CullPreview {
        let image: Data
        let metadata: ARWMetadata?
    }

    /// `includeHead: false` skips the MakerNotes read for frames already
    /// indexed in an earlier run (only the pixels need re-fetching).
    func cullPreview(for photo: CameraPhoto, includeHead: Bool = true) async throws -> CullPreview {
        let screennail = try await compressed(photo, type: 2)
        guard includeHead else { return CullPreview(image: screennail, metadata: nil) }
        let head = try? await read(photo, offset: 0, size: UInt32(min(UInt64(headProbeBytes), photo.sizeBytes)))
        let metadata = head.flatMap { try? CameraHeadParser.parse(head: $0) }
        return CullPreview(image: screennail, metadata: metadata)
    }

    /// Streams the original file to `url` in chunks, for importing a keeper.
    /// Resumable: bytes already in `url` from an interrupted attempt are kept
    /// and the transfer continues from there — a drop at 90% costs 4MB, not
    /// the whole RAW.
    func download(_ photo: CameraPhoto, to url: URL,
                  progress: @Sendable (UInt64) -> Void = { _ in }) async throws {
        let existing = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
        if existing == nil || existing! > photo.sizeBytes {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var offset = try handle.seekToEnd()
        if offset > 0 { log("resuming \(photo.filename) at \(offset >> 20)MB") }
        progress(offset)
        while offset < photo.sizeBytes {
            let size = UInt32(min(UInt64(downloadChunk), photo.sizeBytes - offset))
            let chunk = try await read(photo, offset: offset, size: size)
            guard !chunk.isEmpty else { throw PTPTransport.TransportError.timeout }
            try handle.write(contentsOf: chunk)
            offset += UInt64(chunk.count)
            progress(offset)
        }
    }

    // MARK: - Remote-transfer primitives

    private func compressed(_ photo: CameraPhoto, type: UInt32) async throws -> Data {
        try await transport.require(
            .sonyGetContentsCompressedData,
            parameters: [photo.contentID,
                         SonyRemoteTransfer.fileSelector(slot: photo.slot, fileID: photo.fileID), type],
            expectsData: true)
    }

    private func read(_ photo: CameraPhoto, offset: UInt64, size: UInt32) async throws -> Data {
        try await transport.require(
            .sonyGetContentsData,
            parameters: SonyRemoteTransfer.contentsDataParameters(
                contentID: photo.contentID, slot: photo.slot, fileID: photo.fileID,
                offset: offset, size: size, fileSize: photo.sizeBytes),
            expectsData: true)
    }
}
