import Foundation
import Photos

/// Imports an original pulled off the camera into the Photos library, moving
/// the downloaded file in as a photo resource (RAW stays RAW). This is
/// additive — it never deletes anything, on the card or in the library.
enum CameraImporter {
    static func importToPhotos(fileURL: URL, filename: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            options.shouldMoveFile = true // move the temp file in
            request.addResource(with: .photo, fileURL: fileURL, options: options)
        }
    }
}
