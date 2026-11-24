import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import VisionCullCore

final class ImmichAlbumTests: XCTestCase {
    func testReadOnlyAlbumPreviewCachesAnalysisAndWritesOnlyApprovedChanges() async throws {
        let mock = try PreviewServer()
        let client = try mock.client()
        let albums = try await client.albums()
        XCTAssertEqual(albums.map(\.albumName), ["Trip"])
        let scanner = PhotoScanner(cacheRoot: try temporary(), analyzer: PreviewAnalyzer())
        var review = try await client.scanAlbum(mock.album, scanner: scanner)
        XCTAssertEqual(review.issues.count, 0)
        XCTAssertEqual(review.analyzed, 1)
        XCTAssertEqual(mock.downloads, 1)
        let first = try XCTUnwrap(review.photos.first)
        XCTAssertEqual(first.immichSource?.assetID, mock.image)
        XCTAssertEqual(first.immichSource?.originalChecksum, "checksum-of-original")
        XCTAssertEqual(first.displayName, "original.HEIC")
        XCTAssertEqual(first.existing.description, "Server caption")
        XCTAssertEqual(first.existing.capturedAt, "2024-05-03T18:25:20+02:00")
        XCTAssertEqual(first.existing.latitude, 0)
        XCTAssertEqual(first.existing.longitude, 15)
        XCTAssertEqual(first.existing.rating, 3)
        XCTAssertEqual(first.existing.topics, ["Reise"])
        XCTAssertFalse(first.fromApplePhotos)
        XCTAssertFalse(first.approved)
        XCTAssertEqual(first.analysis.subjects, ["flower"])
        XCTAssertEqual(first.metadata.subjects, ["Flowers"])
        XCTAssertEqual(mock.patchCount, 0)

        mock.bumpRevision()
        let rescan = try await client.scanAlbum(mock.album, scanner: scanner)
        XCTAssertEqual(rescan.reused, 1)
        XCTAssertEqual(rescan.analyzed, 0)
        XCTAssertEqual(mock.downloads, 1)
        XCTAssertNotEqual(rescan.photos.first?.immichSource?.updatedAt, first.immichSource?.updatedAt)
        review = rescan
        review.photos[0].approved = true
        review.photos[0].metadata = first.existing
        review.photos[0].metadata.description = "Confirmed caption"
        let roundTrip = try JSONDecoder().decode(Review.self, from: JSONEncoder().encode(review))
        let plan = try await client.previewBatch([ImmichBatchRequest(photo: roundTrip.photos[0])])
        XCTAssertEqual(mock.patchCount, 0)
        XCTAssertEqual(plan.first?.assetID, mock.image)
        XCTAssertEqual(plan.first?.metadataChanges, ["Description: Server caption → Confirmed caption"])
        XCTAssertEqual(plan.first?.reusedTags, ["Themen/Reise"])

        let results = try await client.applyBatch(plan)
        XCTAssertNil(results.first?.problem)
        XCTAssertEqual(mock.patchCount, 1)
        XCTAssertThrowsError(try XMP.export(review, to: .alongside))
        let output = try XMP.export(review, to: .folder(try temporary()))
        XCTAssertEqual(output.first?.lastPathComponent, "original.xmp")
    }

    func testRemotePreviewRejectsChangedSourceWrongServerAndUploads() async throws {
        let mock = try PreviewServer(legacyAlbum: true)
        let client = try mock.client()
        var review = try await client.scanAlbum(mock.album, scanner: PhotoScanner(cacheRoot: try temporary(), analyzer: PreviewAnalyzer()))
        review.photos[0].approved = true
        let photo = review.photos[0]
        let invalid = try await client.previewBatch([
            ImmichBatchRequest(photo: photo, intent: .upload(album: mock.album)),
            ImmichBatchRequest(photo: photo, intent: .update(UUID())),
        ])
        XCTAssertTrue(invalid.allSatisfy { $0.problem?.contains("original Immich asset") == true })
        let other = try mock.client(server: "https://other.example.invalid")
        let wrongServer = try await other.previewBatch([ImmichBatchRequest(photo: photo)])
        XCTAssertTrue(wrongServer.first?.problem?.contains("different Immich server") == true)
        mock.bumpRevision()
        let stale = try await client.previewBatch([ImmichBatchRequest(photo: photo)])
        XCTAssertTrue(stale.first?.problem?.contains("changed since the scan") == true)
        XCTAssertEqual(mock.patchCount, 0)
    }

    func testAlbumPagingSkipsVideosAndReportsMissingPreviews() async throws {
        let mock = try PreviewServer(missingPreview: true)
        let review = try await mock.client().scanAlbum(
            mock.album, scanner: PhotoScanner(cacheRoot: try temporary(), analyzer: PreviewAnalyzer())
        )
        XCTAssertTrue(review.photos.isEmpty)
        XCTAssertEqual(mock.downloads, 1)
        XCTAssertEqual(review.issues.first?.path, "original.HEIC")
        XCTAssertTrue(review.issues.first?.message.contains("HTTP 404") == true)
    }

    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
}

private struct PreviewAnalyzer: PhotoAnalyzer {
    let cacheVersion = "fixture-preview"
    func analyze(_ file: URL) throws -> ImageAnalysis {
        XCTAssertEqual(file.pathExtension, "png")
        return ImageAnalysis(subjects: ["flower"])
    }
}

private final class PreviewServer: @unchecked Sendable {
    let album = UUID()
    let image = UUID()
    let video = UUID()
    private let tag = UUID()
    private let preview: Data
    private let legacyAlbum: Bool
    private let missingPreview: Bool
    private let lock = NSLock()
    private var version = 1
    private var requestCount = 0
    private var writes = 0

    init(legacyAlbum: Bool = false, missingPreview: Bool = false) throws {
        let sample = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "png", subdirectory: "Fixtures"))
        preview = try Data(contentsOf: sample)
        self.legacyAlbum = legacyAlbum
        self.missingPreview = missingPreview
    }

    var downloads: Int { lock.withLock { requestCount } }
    var patchCount: Int { lock.withLock { writes } }

    func bumpRevision() { lock.withLock { version += 1 } }

    func client(server: String = "https://immich.example.invalid/api/") throws -> ImmichClient {
        try ImmichClient(
            server: XCTUnwrap(URL(string: server)), apiKey: "fixture-key",
            load: { try self.respond($0) },
            sendFile: { _, _ in throw WorkflowError.message("Preview flow must never upload bytes.") },
            fingerprint: { _ in throw WorkflowError.message("Preview flow must never hash a preview as an original.") }
        )
    }

    private func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-key")
        let asset = [ "id": image.uuidString, "checksum": "checksum-of-original", "type": "IMAGE",
                      "isTrashed": false, "originalFileName": "original.HEIC" ] as [String: Any]
        let tags = [["id": tag.uuidString, "value": "Themen/Reise"]]
        let response: Any
        switch (request.httpMethod, url.path) {
        case ("GET", "/api/albums"):
            response = [["id": album.uuidString, "albumName": "Trip", "assetCount": 2]]
        case ("GET", "/api/albums/\(album)"):
            if legacyAlbum { response = ["id": album.uuidString, "assets": [asset]] }
            else { response = ["id": album.uuidString] }
        case ("POST", "/api/search/metadata"):
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(payload["albumIds"] as? [String], [album.uuidString])
            let page = payload["page"] as? Int
            if page == 1 { response = ["assets": ["items": [asset], "nextPage": "2"]] }
            else {
                XCTAssertEqual(page, 2)
                response = ["assets": ["items": [["id": video.uuidString, "checksum": "video", "type": "VIDEO", "isTrashed": false]]]]
            }
        case ("GET", "/api/assets/\(image)"), ("PUT", "/api/assets/\(image)"):
            if request.httpMethod == "PUT" {
                let patch = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
                XCTAssertEqual(patch, ["description": "Confirmed caption"])
                lock.withLock { writes += 1 }
            }
            var full = asset
            full["updatedAt"] = "revision-\(lock.withLock { version })"
            full["fileModifiedAt"] = "2024-05-03T16:25:20Z"
            full["thumbhash"] = "same-preview"
            full["tags"] = tags
            full["exifInfo"] = [
                "description": "Server caption", "dateTimeOriginal": "2024-05-03T18:25:20+02:00",
                "latitude": 0.0, "longitude": 15.0, "rating": 3,
            ] as [String: Any]
            response = full
        case ("GET", "/api/assets/\(image)/thumbnail"):
            XCTAssertEqual(url.query, "size=preview")
            lock.withLock { requestCount += 1 }
            let status = missingPreview ? 404 : 200
            let http = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: "1.1", headerFields: nil))
            return (missingPreview ? Data() : preview, http)
        case ("GET", "/api/tags"):
            response = tags
        default:
            throw WorkflowError.message("Unexpected request: \(request.httpMethod ?? "") \(url.path)")
        }
        let bytes = try JSONSerialization.data(withJSONObject: response)
        let http = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "1.1", headerFields: nil))
        return (bytes, http)
    }
}
