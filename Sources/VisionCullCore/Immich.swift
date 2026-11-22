import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

public final class ImmichClient: Sendable {
    private let endpoint: URL
    private let key: String
    private let load: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let sendFile: @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)
    private let fingerprint: @Sendable (URL) throws -> String

    public convenience init(server: URL, apiKey: String) throws {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        try self.init(
            server: server, apiKey: apiKey,
            load: { try await session.data(for: $0) },
            sendFile: { try await session.upload(for: $0, fromFile: $1) },
            fingerprint: { try Self.checksum($0) }
        )
    }

    init(
        server: URL, apiKey: String,
        load: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        sendFile: @escaping @Sendable (URLRequest, URL) async throws -> (Data, URLResponse),
        fingerprint: @escaping @Sendable (URL) throws -> String
    ) throws {
        let host = server.host ?? ""
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        let scheme = server.scheme?.lowercased()
        guard !host.isEmpty, (scheme == "https" || (scheme == "http" && loopback)),
              server.user == nil, server.password == nil, server.query == nil, server.fragment == nil else {
            throw WorkflowError.message("Enter the Immich server URL with HTTPS (HTTP is accepted on loopback).")
        }
        let headersAreSafe = !apiKey.isEmpty && apiKey.utf8.allSatisfy { (33...126).contains($0) }
        guard headersAreSafe else { throw WorkflowError.message("Enter a valid Immich API key.") }
        endpoint = server.lastPathComponent == "api" ? server : server.appendingPathComponent("api")
        key = apiKey
        self.load = load
        self.sendFile = sendFile
        self.fingerprint = fingerprint
    }

    public func update(_ photo: PhotoEntry, assetID: UUID, addToAlbum album: UUID? = nil) async throws {
        let metadata = try check(photo)
        let checksum = try fingerprint(photo.file)
        guard try FileRevision.read(photo.file) == photo.revision else {
            throw WorkflowError.message("Image changed during checksum verification. Rescan it.")
        }
        let asset: Asset = try await send("GET", "assets/\(assetID.uuidString)")
        guard asset.id == assetID, asset.checksum == checksum, asset.type == "IMAGE", !asset.isTrashed else {
            throw WorkflowError.message("Asset \(assetID) does not match the reviewed image checksum, or is unavailable. Confirm the exact asset in Immich.")
        }
        if let album { try await verifyAlbum(album) }
        do {
            try await apply(metadata, to: assetID, current: asset)
            if let album { try await add(assetID, to: album) }
        } catch {
            throw WorkflowError.message("Immich asset \(assetID): \(error.localizedDescription). Some earlier steps may have succeeded.")
        }
    }

    @discardableResult
    public func upload(_ photo: PhotoEntry, album: UUID) async throws -> UUID {
        let metadata = try check(photo)
        let checksum = try fingerprint(photo.file)
        try await verifyAlbum(album)
        let localID = UUID()
        let check: UploadCheck = try await send(
            "POST", "assets/bulk-upload-check", body: ["assets": [["id": localID.uuidString, "checksum": checksum]]]
        )
        guard check.results.count == 1, let result = check.results.first, result.id == localID else {
            throw WorkflowError.message("Immich could not verify whether this image is new.")
        }
        guard result.action == "accept" else {
            let details = result.assetId.map { " Existing asset ID: \($0.uuidString)." } ?? ""
            throw WorkflowError.message("Immich declined the new upload.\(details) Verify the match before choosing Update.")
        }

        let boundary = "VisionCull-\(UUID().uuidString)"
        let multipart = try makeMultipart(photo, metadata: metadata, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: multipart) }

        var request = request("POST", path: "assets")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(checksum, forHTTPHeaderField: "x-immich-checksum")
        let response = try await sendFile(request, multipart)
        let receipt: UploadReceipt = try decode(response, request: request)
        guard receipt.status == "created" else {
            throw WorkflowError.message("Immich returned \(receipt.status) for asset \(receipt.id). Verify that asset before choosing Update.")
        }
        do {
            let asset: Asset = try await send("GET", "assets/\(receipt.id.uuidString)")
            guard asset.id == receipt.id, asset.checksum == checksum, asset.type == "IMAGE", !asset.isTrashed else {
                throw WorkflowError.message("Immich returned a different checksum or an unavailable asset.")
            }
            try await add(receipt.id, to: album)
            try await apply(metadata, to: receipt.id, current: asset)
        } catch {
            throw WorkflowError.message("Uploaded asset \(receipt.id), but follow-up failed: \(error.localizedDescription). Use Update with this ID to finish.")
        }
        return receipt.id
    }

    private func check(_ photo: PhotoEntry) throws -> PhotoMetadata {
        guard photo.approved else { throw WorkflowError.message("Approve this photo before sending it to Immich.") }
        guard try FileRevision.read(photo.file) == photo.revision else {
            throw WorkflowError.message("Image changed after review. Rescan it.")
        }
        let metadata = try photo.metadata.validated()
        if !metadata.capturedAt.isEmpty && PhotoMetadata.zonedDate(metadata.capturedAt) == nil {
            throw WorkflowError.message("Immich needs an exact capture time with a timezone. Add the offset or leave the date empty for this action.")
        }
        return metadata
    }

    private func request(_ method: String, path: String) -> URLRequest {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
        var request = request(method, path: path)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try decode(try await load(request), request: request)
    }

    private func decode<T: Decodable>(_ result: (Data, URLResponse), request: URLRequest) throws -> T {
        let (data, response) = result
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw WorkflowError.message("Immich \(request.httpMethod ?? "") \(request.url?.path ?? "") returned HTTP \(status).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func verifyAlbum(_ id: UUID) async throws {
        let album: Album = try await send("GET", "albums/\(id.uuidString)")
        guard album.id == id else { throw WorkflowError.message("Immich returned a different target album.") }
    }

    private func add(_ asset: UUID, to album: UUID) async throws {
        let results: [BulkResult] = try await send(
            "PUT", "albums/\(album.uuidString)/assets", body: ["ids": [asset.uuidString]]
        )
        guard results.count == 1, let result = results.first, result.id == asset,
              result.success || result.error == "duplicate" else {
            throw WorkflowError.message("Immich could not add asset \(asset) to album \(album).")
        }
    }

    private func apply(_ metadata: PhotoMetadata, to asset: UUID, current: Asset) async throws {
        var patch: [String: Any] = [:]
        if !metadata.description.isEmpty { patch["description"] = metadata.description }
        if !metadata.capturedAt.isEmpty { patch["dateTimeOriginal"] = metadata.capturedAt }
        if let lat = metadata.latitude, let lon = metadata.longitude {
            patch["latitude"] = lat
            patch["longitude"] = lon
        }
        if !patch.isEmpty {
            let updated: Asset = try await send("PUT", "assets/\(asset.uuidString)", body: patch)
            guard updated.id == asset else { throw WorkflowError.message("Immich returned a different updated asset.") }
        }

        var seen = Set((current.tags ?? []).map { $0.value.lowercased() })
        let tags = (metadata.subjects + [metadata.category]).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        if !tags.isEmpty {
            let tagIDs: [Tag] = try await send("PUT", "tags", body: ["tags": tags])
            let ids = tagIDs.map { $0.id.uuidString }
            guard Set(tagIDs.map { $0.value.lowercased() }) == Set(tags.map { $0.lowercased() }) else {
                throw WorkflowError.message("Immich did not return every requested tag.")
            }
            let _: TagResult = try await send(
                "PUT", "tags/assets", body: ["assetIds": [asset.uuidString], "tagIds": ids]
            )
            let verified: Asset = try await send("GET", "assets/\(asset.uuidString)")
            let values = Set((verified.tags ?? []).map { $0.value.lowercased() })
            guard verified.id == asset, tags.allSatisfy({ values.contains($0.lowercased()) }) else {
                throw WorkflowError.message("Immich did not confirm all associated tags.")
            }
        }
    }

    private func makeMultipart(_ photo: PhotoEntry, metadata: PhotoMetadata, boundary: String) throws -> URL {
        let manager = FileManager.default
        let file = manager.temporaryDirectory.appendingPathComponent("visioncull-upload-\(UUID().uuidString)")
        try Data().write(to: file, options: .withoutOverwriting)
        do {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            func write(_ string: String) throws { try output.write(contentsOf: Data(string.utf8)) }
            func value(_ name: String, _ value: String) throws {
                try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
            }
            let formatter = ISO8601DateFormatter()
            let modified = formatter.string(from: photo.revision.modified)
            let created = try photo.file.resourceValues(forKeys: [.creationDateKey]).creationDate
            try value("fileCreatedAt", metadata.capturedAt.isEmpty ? created.map(formatter.string(from:)) ?? modified : metadata.capturedAt)
            try value("fileModifiedAt", modified)
            let filename = photo.file.lastPathComponent.map { char in
                char == "\"" || char == "\\" || char.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                    ? "_" : String(char)
            }.joined()
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
            let input = try FileHandle(forReadingFrom: photo.file)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            guard try FileRevision.read(photo.file) == photo.revision else {
                throw WorkflowError.message("Image changed when preparing upload. Rescan it.")
            }
            try write("\r\n--\(boundary)--\r\n")
            return file
        } catch {
            try? manager.removeItem(at: file)
            throw error
        }
    }

    private static func checksum(_ file: URL) throws -> String {
        #if canImport(CryptoKit)
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var sha = Insecure.SHA1() // Required by Immich's asset-identity API.
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            sha.update(data: chunk)
        }
        return Data(sha.finalize()).base64EncodedString()
        #else
        throw WorkflowError.message("Immich image checksums require the macOS build.")
        #endif
    }

    private struct Asset: Decodable { let id: UUID; let checksum: String; let type: String; let isTrashed: Bool; let tags: [Tag]? }
    private struct Album: Decodable { let id: UUID }
    private struct Tag: Decodable { let id: UUID; let value: String }
    private struct TagResult: Decodable { let count: Int }
    private struct BulkResult: Decodable { let id: UUID; let success: Bool; let error: String? }
    private struct UploadReceipt: Decodable { let id: UUID; let status: String }
    private struct UploadCheck: Decodable {
        struct Result: Decodable { let id: UUID; let action: String; let assetId: UUID? }
        let results: [Result]
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
