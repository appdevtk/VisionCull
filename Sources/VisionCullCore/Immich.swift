import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum ImmichBatchIntent: Equatable, Sendable {
    case matchExisting
    case update(UUID)
    case upload(album: UUID)
}

public struct ImmichBatchRequest: Sendable, Identifiable {
    public let photo: PhotoEntry
    public var intent: ImmichBatchIntent
    public var id: String { photo.id }

    public init(photo: PhotoEntry, intent: ImmichBatchIntent = .matchExisting) {
        self.photo = photo
        self.intent = intent
    }
}

public struct ImmichBatchPreview: Identifiable, Sendable {
    public let id: String
    public let path: String
    public let assetID: UUID?
    public let albumID: UUID?
    public let reusedTags: [String]
    public let newTags: [String]
    public let metadataChanges: [String]
    public let problem: String?
    public var isReady: Bool { problem == nil && plan != nil }
    fileprivate let plan: ImmichClient.Prepared?
}

public struct ImmichBatchResult: Identifiable, Sendable {
    public let id: String
    public let path: String
    public let assetID: UUID?
    public let problem: String?
}

public final class ImmichClient: Sendable {
    private let endpoint: URL
    private let key: String
    private let load: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let sendFile: @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)
    private let tagRules: TagRules
    private let fingerprint: @Sendable (URL) throws -> String

    public convenience init(server: URL, apiKey: String, aliases: [TagAlias] = []) throws {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        try self.init(
            server: server, apiKey: apiKey,
            load: { try await session.data(for: $0) },
            sendFile: { try await session.upload(for: $0, fromFile: $1) },
            fingerprint: { try Self.checksum($0) }, aliases: aliases
        )
    }

    init(
        server: URL, apiKey: String,
        load: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
        sendFile: @escaping @Sendable (URLRequest, URL) async throws -> (Data, URLResponse),
        fingerprint: @escaping @Sendable (URL) throws -> String, aliases: [TagAlias] = []
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
        self.tagRules = TagRules(custom: aliases)
    }

    public func update(_ photo: PhotoEntry, assetID: UUID, addToAlbum album: UUID? = nil) async throws {
        let prepared = try await prepare(ImmichBatchRequest(photo: photo, intent: .update(assetID)), updateAlbum: album)
        _ = try await execute(prepared)
    }

    @discardableResult
    public func upload(_ photo: PhotoEntry, album: UUID) async throws -> UUID {
        let prepared = try await prepare(ImmichBatchRequest(photo: photo, intent: .upload(album: album)))
        return try await execute(prepared)
    }

    /// Performs checksum lookups and other read-only preflight checks. The upload-check POST does not modify Immich.
    public func previewBatch(_ requests: [ImmichBatchRequest]) async throws -> [ImmichBatchPreview] {
        var records = [(ImmichBatchRequest, Result<Prepared, Error>)]()
        for request in requests {
            try Task.checkCancellation()
            do { records.append((request, .success(try await prepare(request)))) }
            catch is CancellationError { throw CancellationError() }
            catch { records.append((request, .failure(error))) }
        }
        let plans = records.compactMap { try? $0.1.get() }
        let destinations = Dictionary(grouping: plans, by: \.destination)
        return records.map { request, result in
            switch result {
            case .failure(let error):
                return preview(request, plan: nil, problem: error.localizedDescription)
            case .success(let plan):
                let conflict = (destinations[plan.destination]?.count ?? 0) > 1
                return preview(request, plan: plan, problem: conflict ? "More than one selected photo targets the same asset or upload checksum." : nil)
            }
        }
    }

    /// Revalidates each checked item immediately before sending. Reports each result independently.
    public func applyBatch(_ rows: [ImmichBatchPreview]) async throws -> [ImmichBatchResult] {
        var results = [ImmichBatchResult]()
        var sent = Set<String>()
        for row in rows {
            try Task.checkCancellation()
            do {
                guard row.isReady, let old = row.plan, old.endpoint == endpoint,
                      sent.insert(old.destination).inserted else {
                    throw WorkflowError.message("Select a unique, ready preview row for this server.")
                }
                let current = try await prepare(old.request)
                guard old.accepts(current) else {
                    throw WorkflowError.message("The target, file, or tag mapping changed. Preview again before sending.")
                }
                let id = try await execute(current)
                results.append(ImmichBatchResult(id: row.id, path: row.path, assetID: id, problem: nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                results.append(ImmichBatchResult(id: row.id, path: row.path, assetID: row.assetID, problem: error.localizedDescription))
            }
        }
        return results
    }

    public func similarTags() async throws -> [TagSimilarity] {
        let tags: [Tag] = try await send("GET", "tags")
        var grouped = [TagGroup: [String]]()
        for tag in tags {
            let planned = PlannedTag(path: tag.value, id: tag.id)
            if let group = planned.group { grouped[group, default: []].append(tag.value) }
        }
        return TagInventory.similar(in: grouped, rules: tagRules)
    }

    private func preview(_ request: ImmichBatchRequest, plan: Prepared?, problem: String?) -> ImmichBatchPreview {
        let changes: [String] = plan.map { prepared in
            prepared.outboundFields.keys.sorted().map { key in
                let value = prepared.outboundFields[key] ?? ""
                if let before = prepared.remoteFields[key], before != value {
                    return "\(key): \(before) → \(value)"
                }
                return "\(key): \(value)"
            }
        } ?? []
        return ImmichBatchPreview(
            id: request.id, path: request.photo.relativePath, assetID: plan?.asset?.id, albumID: plan?.album,
            reusedTags: plan?.tags.filter { $0.id != nil }.map(\.path) ?? [],
            newTags: plan?.tags.filter { $0.id == nil }.map(\.path) ?? [],
            metadataChanges: changes, problem: problem, plan: plan
        )
    }

    private func prepare(_ request: ImmichBatchRequest, updateAlbum: UUID? = nil) async throws -> Prepared {
        let photo = request.photo
        let metadata = try check(photo)
        let checksum = try fingerprint(photo.file)
        guard try FileRevision.read(photo.file) == photo.revision else {
            throw WorkflowError.message("Image changed during checksum verification. Rescan it.")
        }

        let target: UUID?
        let album: UUID?
        switch request.intent {
        case .update(let id):
            target = id
            album = updateAlbum
        case .matchExisting:
            target = try await findExisting(checksum)
            album = nil
        case .upload(let id):
            try await verifyAlbum(id)
            let result = try await uploadCheck(checksum)
            guard result.action == "accept", result.assetId == nil else {
                let details = result.assetId.map { " Existing asset ID: \($0.uuidString)." } ?? ""
                throw WorkflowError.message("Immich declined the new upload.\(details) Verify the match before choosing Update.")
            }
            target = nil
            album = id
        }

        let asset: Asset?
        if let target {
            asset = try await checkedAsset(target, checksum: checksum)
            if let album { try await verifyAlbum(album) }
        } else { asset = nil }
        let tags = try await planTags(for: metadata, current: asset?.tags ?? [])
        return Prepared(request: request, endpoint: endpoint, metadata: metadata, checksum: checksum, asset: asset, album: album, tags: tags)
    }

    private func findExisting(_ checksum: String) async throws -> UUID {
        let result: ChecksumSearch = try await send(
            "POST", "search/metadata", body: ["checksum": checksum, "type": "IMAGE", "size": 2, "withStacked": true]
        )
        if result.assets.items.isEmpty {
            throw WorkflowError.message("No existing asset matched. Enter a verified asset ID or choose a new upload and album.")
        }
        guard result.assets.items.count == 1, let item = result.assets.items.first,
              result.assets.nextPage == nil, result.assets.nextCursor == nil,
              item.checksum == checksum, item.type == "IMAGE", !item.isTrashed else {
            let ids = result.assets.items.map { $0.id.uuidString }.joined(separator: ", ")
            throw WorkflowError.message("The checksum did not resolve to one available image. Enter the verified asset ID. Candidates: \(ids)")
        }
        return item.id
    }

    private func uploadCheck(_ checksum: String) async throws -> UploadCheck.Result {
        let localID = UUID()
        let reply: UploadCheck = try await send(
            "POST", "assets/bulk-upload-check", body: ["assets": [["id": localID.uuidString, "checksum": checksum]]]
        )
        guard reply.results.count == 1, let result = reply.results.first, result.id == localID else {
            throw WorkflowError.message("Immich could not verify the image checksum lookup.")
        }
        return result
    }

    private func checkedAsset(_ id: UUID, checksum: String) async throws -> Asset {
        let asset: Asset = try await send("GET", "assets/\(id.uuidString)")
        guard asset.id == id, asset.checksum == checksum, asset.type == "IMAGE", !asset.isTrashed else {
            throw WorkflowError.message("Asset \(id) does not match the reviewed image checksum, or is unavailable. Confirm the exact asset in Immich.")
        }
        return asset
    }

    private func execute(_ plan: Prepared) async throws -> UUID {
        if let asset = plan.asset {
            guard try FileRevision.read(plan.request.photo.file) == plan.request.photo.revision else {
                throw WorkflowError.message("Image changed after preview. Rescan it.")
            }
            do {
                try await apply(plan.metadata, to: asset.id, current: asset, tags: plan.tags)
                if let album = plan.album { try await add(asset.id, to: album) }
                return asset.id
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw WorkflowError.message("Immich asset \(asset.id): \(error.localizedDescription). Some earlier steps may have succeeded.")
            }
        }
        guard let album = plan.album else { throw WorkflowError.message("Choose a target album before uploading.") }
        let boundary = "VisionCull-\(UUID().uuidString)"
        let multipart = try makeMultipart(plan.request.photo, metadata: plan.metadata, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: multipart) }

        var request = request("POST", path: "assets")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(plan.checksum, forHTTPHeaderField: "x-immich-checksum")
        let response = try await sendFile(request, multipart)
        let receipt: UploadReceipt = try decode(response, request: request)
        guard receipt.status == "created" else {
            throw WorkflowError.message("Immich returned \(receipt.status) for asset \(receipt.id). Verify that asset before choosing Update.")
        }
        do {
            let asset = try await checkedAsset(receipt.id, checksum: plan.checksum)
            try await add(receipt.id, to: album)
            try await apply(plan.metadata, to: receipt.id, current: asset, tags: plan.tags)
        } catch {
            throw WorkflowError.message("Uploaded asset \(receipt.id), but follow-up failed: \(error.localizedDescription). Use Update with this ID to finish.")
        }
        return receipt.id
    }

    fileprivate struct Prepared: Sendable {
        let request: ImmichBatchRequest
        let endpoint: URL
        let metadata: PhotoMetadata
        let checksum: String
        fileprivate let asset: Asset?
        let album: UUID?
        fileprivate let tags: [PlannedTag]

        var destination: String { asset.map { "asset:\($0.id)" } ?? "upload:\(checksum)" }

        var outboundFields: [String: String] {
            var fields = [String: String]()
            if !metadata.description.isEmpty { fields["Description"] = metadata.description }
            if !metadata.capturedAt.isEmpty { fields["Capture date"] = metadata.capturedAt }
            if let rating = metadata.rating { fields["Stars"] = String(rating) }
            if let lat = metadata.latitude, let lon = metadata.longitude { fields["GPS"] = "\(lat), \(lon)" }
            return fields
        }

        var remoteFields: [String: String] {
            guard let details = asset?.exifInfo else { return [:] }
            var fields = [String: String]()
            fields["Description"] = details.description
            fields["Capture date"] = details.dateTimeOriginal
            fields["Stars"] = details.rating.map { String($0) }
            if let lat = details.latitude, let lon = details.longitude { fields["GPS"] = "\(lat), \(lon)" }
            let targeted = outboundFields
            return fields.filter { targeted[$0.key] != nil }
        }

        func accepts(_ current: Prepared) -> Bool {
            guard destination == current.destination, checksum == current.checksum, album == current.album,
                  metadata == current.metadata, remoteFields == current.remoteFields, tags.count == current.tags.count else { return false }
            // A tag created by an earlier item may gain an ID. Its approved path must still match.
            return zip(tags, current.tags).allSatisfy { old, new in
                old.path == new.path && (old.id == nil || old.id == new.id)
            }
        }
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

    private func apply(_ metadata: PhotoMetadata, to asset: UUID, current: Asset, tags: [PlannedTag]) async throws {
        var patch: [String: Any] = [:]
        if !metadata.description.isEmpty { patch["description"] = metadata.description }
        if !metadata.capturedAt.isEmpty { patch["dateTimeOriginal"] = metadata.capturedAt }
        if let rating = metadata.rating { patch["rating"] = rating }
        if let lat = metadata.latitude, let lon = metadata.longitude {
            patch["latitude"] = lat
            patch["longitude"] = lon
        }
        if !patch.isEmpty {
            let updated: Asset = try await send("PUT", "assets/\(asset.uuidString)", body: patch)
            guard updated.id == asset else { throw WorkflowError.message("Immich returned a different updated asset.") }
        }

        let attached = Set((current.tags ?? []).map { TagRules.pathKey($0.value) })
        let pending = tags.filter { !attached.contains(TagRules.pathKey($0.path)) }
        guard !pending.isEmpty else { return }
        var ids = Set(pending.compactMap(\.id))
        let names = pending.filter { $0.id == nil }.map(\.path)
        if !names.isEmpty {
            let returned: [Tag] = try await send("PUT", "tags", body: ["tags": names])
            let requested = Set(names.map(TagRules.pathKey))
            let matched = returned.filter { requested.contains(TagRules.pathKey($0.value)) }
            guard Set(matched.map { TagRules.pathKey($0.value) }) == requested, matched.count == requested.count else {
                throw WorkflowError.message("Immich did not return every requested tag.")
            }
            ids.formUnion(matched.map(\.id))
        }
        let _: TagResult = try await send(
            "PUT", "tags/assets", body: ["assetIds": [asset.uuidString], "tagIds": ids.map(\.uuidString).sorted()]
        )
        let verified: Asset = try await send("GET", "assets/\(asset.uuidString)")
        let confirmed = Set((verified.tags ?? []).map(\.id))
        guard verified.id == asset, ids.isSubset(of: confirmed) else {
            throw WorkflowError.message("Immich did not confirm all associated tags.")
        }
    }

    private func planTags(for metadata: PhotoMetadata, current: [Tag]) async throws -> [PlannedTag] {
        let paths = (metadata.subjects + [metadata.category] + metadata.structuredKeywords).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return [] }
        let serverTags: [Tag] = try await send("GET", "tags")
        let currentIDs = Set(current.map(\.id))
        let inventory = (current + serverTags.filter { !currentIDs.contains($0.id) }.sorted { $0.value < $1.value })
            .map { PlannedTag(path: $0.value, id: $0.id) }
        var planned = [PlannedTag]()
        for path in paths {
            let available = inventory + planned
            let candidate = PlannedTag(path: path, id: nil)
            let exact = available.first { TagRules.pathKey($0.path) == TagRules.pathKey(path) }
            let group = candidate.group
            let matching = group == nil ? [] : available.filter { $0.group == group || $0.group == .subjects }
            let associated = group.flatMap { group in
                matching.first { option in
                    guard let id = option.id, currentIDs.contains(id) else { return false }
                    return tagRules.equivalent(candidate.leaf, option.leaf, in: group)
                }
            }
            let resolved: PlannedTag
            if let preferred = associated ?? exact {
                resolved = preferred
            } else if let group {
                let names = matching.map(\.leaf)
                let match = try tagRules.resolve(
                    candidate.leaf, in: group, candidates: names
                )
                if match.existing, let known = matching.first(where: { $0.leaf == match.name }) {
                    resolved = known
                } else {
                    resolved = PlannedTag(path: candidate.prefix + match.name, id: nil)
                }
            } else {
                resolved = candidate
            }
            if !planned.contains(where: { TagRules.pathKey($0.path) == TagRules.pathKey(resolved.path) }) {
                planned.append(resolved)
            }
        }
        return planned
    }

    fileprivate struct PlannedTag: Sendable {
        let path: String
        let id: UUID?

        var leaf: String { path.split(separator: "/").last.map(String.init) ?? path }
        var prefix: String { String(path.dropLast(leaf.count)) }

        var group: TagGroup? {
            let parts = path.split(separator: "/")
            if parts.count == 1 { return .subjects }
            guard parts.count >= 2 else { return nil }
            switch TagRules.key(String(parts[parts.count - 2])) {
            case "topic", "topics", "theme", "themes", "thema", "themen": return .topics
            case "mood", "moods", "stimmung", "stimmungen": return .moods
            case "style", "styles", "bildstil", "bildstile", "stil", "stile": return .styles
            default: return nil
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

    fileprivate struct Asset: Decodable, Sendable {
        let id: UUID
        let checksum: String
        let type: String
        let isTrashed: Bool
        let tags: [Tag]?
        let exifInfo: Exif?
    }

    fileprivate struct Exif: Decodable, Sendable {
        let description: String?
        let dateTimeOriginal: String?
        let latitude: Double?
        let longitude: Double?
        let rating: Int?
    }
    private struct Album: Decodable { let id: UUID }
    fileprivate struct Tag: Decodable, Sendable { let id: UUID; let value: String }
    private struct TagResult: Decodable { let count: Int }
    private struct BulkResult: Decodable { let id: UUID; let success: Bool; let error: String? }
    private struct UploadReceipt: Decodable { let id: UUID; let status: String }
    private struct ChecksumSearch: Decodable {
        struct Results: Decodable {
            let items: [Asset]
            let nextPage: String?
            let nextCursor: String?
        }
        let assets: Results
    }
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
