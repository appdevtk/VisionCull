import Foundation

/// Identity of the original on Immich, independent of the bytes of its cached preview.
public struct ImmichPhotoSource: Codable, Equatable, Sendable {
    public let endpoint: URL
    public let albumID: UUID
    public let assetID: UUID
    public let originalChecksum: String
    public let updatedAt: String
}

public struct ImmichAlbum: Decodable, Sendable, Identifiable {
    public let id: UUID
    public let albumName: String
    public let assetCount: Int
}

extension ImmichClient {
    public func albums() async throws -> [ImmichAlbum] {
        let albums: [ImmichAlbum] = try await send("GET", "albums")
        return albums.sorted { first, second in
            let result = first.albumName.localizedStandardCompare(second.albumName)
            return result == .orderedSame ? first.id.uuidString < second.id.uuidString : result == .orderedAscending
        }
    }

    /// Downloads only preview derivatives. Asset metadata and identity come from Immich directly.
    public func scanAlbum(_ albumID: UUID, scanner: PhotoScanner = PhotoScanner()) async throws -> Review {
        let response: AlbumDetail = try await send("GET", "albums/\(albumID.uuidString)")
        guard response.id == albumID else { throw WorkflowError.message("Immich returned a different album.") }
        let listing: [Asset]
        if let assets = response.assets { listing = assets }
        else { listing = try await albumAssets(albumID) }
        var inputs = [PhotoInput]()
        var issues = [ScanIssue]()
        var seen = Set<UUID>()
        for asset in listing where asset.type == "IMAGE" && !asset.isTrashed && seen.insert(asset.id).inserted {
            try Task.checkCancellation()
            let filename = Self.displayFilename(asset.originalFileName, fallback: asset.id)
            do {
                let full = try await checkedAsset(asset.id, checksum: asset.checksum)
                guard let stamp = full.updatedAt, !stamp.isEmpty, !full.checksum.isEmpty else {
                    throw WorkflowError.message("Immich did not return an original checksum and asset revision.")
                }
                let source = ImmichPhotoSource(
                    endpoint: endpoint, albumID: albumID, assetID: full.id, originalChecksum: full.checksum, updatedAt: stamp
                )
                let preview = try await cachedPreview(for: full, root: scanner.cacheRoot)
                inputs.append(PhotoInput(
                    id: "immich:\(endpoint.absoluteString)|\(full.id.uuidString)", file: preview,
                    relativePath: "Immich/\(albumID.uuidString)/\(full.id.uuidString)/\(filename)",
                    libraryMetadata: full.metadata, immichSource: source
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.append(ScanIssue(path: filename, message: error.localizedDescription))
            }
        }
        try Task.checkCancellation()
        var review = try scanner.inspect(inputs)
        review.issues.insert(contentsOf: issues, at: 0)
        return review
    }

    private func albumAssets(_ albumID: UUID) async throws -> [Asset] {
        var current = 1
        var assets = [Asset]()
        var seen = Set<UUID>()
        while true {
            try Task.checkCancellation()
            let result: AlbumSearch = try await send("POST", "search/metadata", body: [
                "albumIds": [albumID.uuidString], "type": "IMAGE", "page": current, "size": 100,
            ])
            if !result.assets.items.allSatisfy({ seen.insert($0.id).inserted }) {
                throw WorkflowError.message("Immich returned repeated album pages. Retry the scan.")
            }
            assets += result.assets.items
            guard let next = result.assets.nextPage else {
                guard result.assets.nextCursor == nil else {
                    throw WorkflowError.message("Immich did not provide a page number for the rest of this album.")
                }
                return assets
            }
            guard let page = Int(next), page > current, !result.assets.items.isEmpty else {
                throw WorkflowError.message("Immich returned an invalid album page.")
            }
            current = page
        }
    }

    private func cachedPreview(for asset: Asset, root: URL) async throws -> URL {
        let variant = asset.isEdited == true ? asset.updatedAt : nil
        let descriptor = PreviewDescriptor(
            endpoint: endpoint, id: asset.id, checksum: asset.checksum,
            modified: asset.fileModifiedAt, thumbhash: asset.thumbhash, editedRevision: variant
        )
        let version = PhotoScanner.cacheKey([asset.checksum, asset.fileModifiedAt ?? "", asset.thumbhash ?? "", variant ?? ""].joined(separator: "\n"))
        let folder = root.appendingPathComponent("immich-previews", isDirectory: true)
            .appendingPathComponent(PhotoScanner.cacheKey(endpoint.absoluteString), isDirectory: true)
            .appendingPathComponent(asset.id.uuidString, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        let record = folder.appendingPathComponent("preview.json")
        if let cached = Self.cachedFile(at: record, matching: descriptor) { return cached }
        let bytes = try await previewImage(asset.id)
        guard let ext = Self.previewExtension(bytes) else {
            throw WorkflowError.message("Immich did not return a JPEG, WebP or PNG preview.")
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try FileAccessLock(url: folder.appendingPathComponent("preview.lock"))
        defer { withExtendedLifetime(lock) {} }
        if let cached = Self.cachedFile(at: record, matching: descriptor) { return cached }
        let file = folder.appendingPathComponent("preview." + ext)
        try bytes.write(to: file, options: .atomic)
        let manifest = PreviewRecord(descriptor: descriptor, extensionName: ext, revision: try FileRevision.read(file))
        try JSONEncoder().encode(manifest).write(to: record, options: .atomic)
        return file
    }

    private static func cachedFile(at record: URL, matching descriptor: PreviewDescriptor) -> URL? {
        guard let data = try? Data(contentsOf: record),
              let info = try? JSONDecoder().decode(PreviewRecord.self, from: data),
              info.descriptor == descriptor, ["jpg", "webp", "png"].contains(info.extensionName) else { return nil }
        let file = record.deletingLastPathComponent().appendingPathComponent("preview." + info.extensionName)
        return (try? FileRevision.read(file)) == info.revision ? file : nil
    }

    private static func previewExtension(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if data.starts(with: Data("RIFF".utf8)), data.count >= 12, data.dropFirst(8).starts(with: Data("WEBP".utf8)) {
            return "webp"
        }
        return nil
    }

    private static func displayFilename(_ name: String?, fallback id: UUID) -> String {
        let leaf = name?.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        if leaf.isEmpty || leaf == "." || leaf == ".." || leaf.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return id.uuidString + ".jpg"
        }
        return leaf
    }

    private struct PreviewDescriptor: Codable, Equatable {
        let endpoint: URL
        let id: UUID
        let checksum: String
        let modified: String?
        let thumbhash: String?
        let editedRevision: String?
    }

    private struct PreviewRecord: Codable {
        let descriptor: PreviewDescriptor
        let extensionName: String
        let revision: FileRevision
    }

    private struct AlbumDetail: Decodable {
        let id: UUID
        let assets: [Asset]?
    }

    private struct AlbumSearch: Decodable {
        struct Page: Decodable {
            let items: [Asset]
            let nextPage: String?
            let nextCursor: String?
        }
        let assets: Page
    }
}
