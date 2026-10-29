#if DEBUG
import Photos
import Foundation

/// Dev-only: imports camera fixtures (ARW/RAF/JPEG) into the photo library so the app can be
/// exercised in the simulator, where `simctl addmedia` refuses RAW files.
///
/// Workflow (see README):
///   cp fixtures/*.ARW "$(xcrun simctl get_app_container booted app.vampire.Vampire data)/Documents/"
///   relaunch the app → files import → moved to Documents/imported/.
///
/// Compiled out of release builds entirely.
enum DevFixtureImporter {
    static func importPending() async {
        let documents = URL.documentsDirectory
        let arws = ((try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: nil
        )) ?? []).filter { ["arw", "raf", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        guard !arws.isEmpty else { return }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                for url in arws {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false
                    request.addResource(with: .photo, fileURL: url, options: options)
                }
            }
            // Park imported files so a relaunch doesn't duplicate them.
            let imported = documents.appending(path: "imported")
            try? FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
            for url in arws {
                try? FileManager.default.moveItem(
                    at: url,
                    to: imported.appending(path: url.lastPathComponent)
                )
            }
            log.info("dev fixture import: \(arws.count) ARW(s) added to library")
        } catch {
            log.error("dev fixture import failed: \(error.localizedDescription)")
        }
    }
}
#endif
