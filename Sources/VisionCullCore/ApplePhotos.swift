import Foundation
#if os(macOS)
import CryptoKit
import Photos
#endif

public enum ApplePhotos {
    /// Reads still-photo original resources into the private working cache. iCloud is opt-in.
    public static func scan(
        scanner: PhotoScanner, limit: Int = 50, allowICloud: Bool = false
    ) async throws -> Review {
        guard limit > 0 else { throw WorkflowError.message("The Apple Photos limit must be positive.") }
        #if os(macOS)
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil else {
            throw WorkflowError.message("Use the packaged VisionCull app or CLI (Scripts/build-macos.sh) for Apple Photos access.")
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw WorkflowError.message("Allow VisionCull to access Apple Photos in System Settings → Privacy & Security → Photos.")
        }
        let options = PHFetchOptions()
        options.fetchLimit = limit
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var issues = [ScanIssue]()
        var inputs = [PhotoInput]()
        for index in 0..<assets.count {
            try Task.checkCancellation()
            let asset = assets.object(at: index)
            do {
                inputs.append(try await stage(asset, root: scanner.cacheRoot, allowICloud: allowICloud))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.append(ScanIssue(path: asset.localIdentifier, message: error.localizedDescription))
            }
        }
        var review = try scanner.inspect(inputs)
        review.issues.insert(contentsOf: issues, at: 0)
        return review
        #else
        throw WorkflowError.message("Apple Photos is available only on macOS.")
        #endif
    }

    #if os(macOS)
    private static func stage(_ asset: PHAsset, root: URL, allowICloud: Bool) async throws -> PhotoInput {
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo }) else {
            throw WorkflowError.message("No still-image original is available for this Photos asset.")
        }
        let identifier = digest(asset.localIdentifier)
        let revision = digest(String(asset.modificationDate?.timeIntervalSince1970 ?? 0) + "/" + resource.originalFilename)
        let filename = URL(fileURLWithPath: resource.originalFilename).lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/") else {
            throw WorkflowError.message("Invalid Apple Photos resource filename.")
        }
        let directory = root.appendingPathComponent("apple-originals", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
        let destination = directory.appendingPathComponent(filename)
        let manager = FileManager.default
        if (try? FileRevision.read(destination)) == nil {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(UUID().uuidString)
            defer { try? manager.removeItem(at: temporary) }
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = allowICloud
            do {
                try await PHAssetResourceManager.default().writeData(for: resource, toFile: temporary, options: options)
            } catch {
                let hint = allowICloud ? "" : " Enable iCloud downloads if the original is online only."
                throw WorkflowError.message("\(filename): \(error.localizedDescription)\(hint)")
            }
            try Task.checkCancellation()
            do { try manager.moveItem(at: temporary, to: destination) }
            catch {
                guard (try? FileRevision.read(destination)) != nil else { throw error }
            }
        }
        let point = asset.location?.coordinate
        let metadata = PhotoMetadata(
            capturedAt: asset.creationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            latitude: point?.latitude, longitude: point?.longitude
        )
        return PhotoInput(
            id: "photos:" + asset.localIdentifier, file: destination,
            relativePath: "Apple Photos/" + identifier + "/" + filename,
            libraryMetadata: metadata
        )
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    #endif
}
