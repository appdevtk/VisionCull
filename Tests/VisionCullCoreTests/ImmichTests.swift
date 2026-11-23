import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import VisionCullCore

final class ImmichTests: XCTestCase {
    func testMismatchedAssetIDDoesNotWriteToServer() async throws {
        let asset = UUID()
        let photo = try makePhoto()
        let client = try client { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/assets/\(asset)")
            return ["id": asset.uuidString, "checksum": "different", "type": "IMAGE", "isTrashed": false]
        }
        do {
            try await client.update(photo, assetID: asset)
            XCTFail("Mismatched checksum should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not match"))
        }
    }

    func testKnownExistingImageIsNeverUploadedAsNew() async throws {
        let asset = UUID()
        let album = UUID()
        let photo = try makePhoto()
        let client = try client { request in
            if request.httpMethod == "GET", request.url?.path == "/api/albums/\(album)" {
                return ["id": album.uuidString]
            }
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/assets/bulk-upload-check")
            let body = try Self.requestBody(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [[String: String]]])
            let item = try XCTUnwrap(json["assets"]?.first)
            XCTAssertEqual(item["checksum"], "test-checksum")
            return ["results": [["id": item["id"] ?? "", "action": "reject", "assetId": asset.uuidString]]]
        }
        do {
            _ = try await client.upload(photo, album: album)
            XCTFail("Existing image should require an explicit update")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(asset.uuidString))
        }
    }

    func testVerifiedIDReceivesOnlyApprovedNonemptyFields() async throws {
        let asset = UUID()
        var photo = try makePhoto()
        photo.metadata.description = "Confirmed caption"
        photo.metadata.latitude = 0
        photo.metadata.longitude = 0
        let client = try client { request in
            XCTAssertEqual(request.url?.path, "/api/assets/\(asset)")
            if request.httpMethod == "PUT" {
                let data = try Self.requestBody(request)
                let values = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(values["description"] as? String, "Confirmed caption")
                XCTAssertEqual(values["latitude"] as? Double, 0)
                XCTAssertEqual(values["longitude"] as? Double, 0)
                XCTAssertNil(values["dateTimeOriginal"])
            } else {
                XCTAssertEqual(request.httpMethod, "GET")
            }
            return ["id": asset.uuidString, "checksum": "test-checksum", "type": "IMAGE", "isTrashed": false]
        }
        try await client.update(photo, assetID: asset)
    }

    func testConfirmedSearchTagsAndStarsReachTheVerifiedAsset() async throws {
        let asset = UUID()
        let topicID = UUID()
        let moodID = UUID()
        let styleID = UUID()
        let relatedParent = UUID()
        let existing = ["id": moodID.uuidString, "value": "VisionCull/Moods/Calm"]
        let topic = ["id": topicID.uuidString, "value": "VisionCull/Topics/Travel"]
        let style = ["id": styleID.uuidString, "value": "VisionCull/Styles/Warm tones"]
        var photo = try makePhoto()
        photo.metadata = PhotoMetadata(topics: ["Travel"], moods: ["Calm"], styles: ["Warm tones"], rating: 4)
        let associated = AttachmentRecord()
        let client = try client { request in
            switch (request.httpMethod, request.url?.path) {
            case ("PUT", "/api/assets/\(asset)"):
                let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: Int])
                XCTAssertEqual(values, ["rating": 4])
            case ("PUT", "/api/tags"):
                let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: [String]])
                XCTAssertEqual(values["tags"], [topic["value"]!, style["value"]!])
                return [topic, style, ["id": relatedParent.uuidString, "value": "VisionCull/Topics"]]
            case ("PUT", "/api/tags/assets"):
                let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: [String]])
                XCTAssertEqual(values["assetIds"], [asset.uuidString])
                XCTAssertEqual(Set(values["tagIds"] ?? []), Set([topicID.uuidString, styleID.uuidString]))
                associated.set()
                return ["count": 2]
            case ("GET", "/api/assets/\(asset)"):
                break
            default:
                XCTFail("Unexpected request: \(request)")
            }
            return [
                "id": asset.uuidString, "checksum": "test-checksum", "type": "IMAGE", "isTrashed": false,
                "tags": associated.value ? [existing, topic, style] : [existing],
            ]
        }
        try await client.update(photo, assetID: asset)
        XCTAssertTrue(associated.value)
    }

    func testExplicitNewUploadIsAttachedToTheRequestedAlbum() async throws {
        let asset = UUID()
        let album = UUID()
        let photo = try makePhoto()
        let albumAttached = AttachmentRecord()
        let client = try client { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/albums/\(album)"):
                return ["id": album.uuidString]
            case ("POST", "/api/assets/bulk-upload-check"):
                let body = try Self.requestBody(request)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [[String: String]]])
                let id = try XCTUnwrap(json["assets"]?.first?["id"])
                return ["results": [["id": id, "action": "accept"]]]
            case ("POST", "/api/assets"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-immich-checksum"), "test-checksum")
                XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
                return ["id": asset.uuidString, "status": "created"]
            case ("GET", "/api/assets/\(asset)"):
                return ["id": asset.uuidString, "checksum": "test-checksum", "type": "IMAGE", "isTrashed": false]
            case ("PUT", "/api/albums/\(album)/assets"):
                let body = try Self.requestBody(request)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [String]])
                XCTAssertEqual(json["ids"], [asset.uuidString])
                albumAttached.set()
                return [["id": asset.uuidString, "success": true]]
            default:
                XCTFail("Unexpected request: \(request)")
                return [String: String]()
            }
        }
        let uploaded = try await client.upload(photo, album: album)
        XCTAssertEqual(uploaded, asset)
        XCTAssertTrue(albumAttached.value)
    }

    func testPendingPhotoIsRejectedBeforeRequest() async throws {
        var photo = try makePhoto()
        photo.approved = false
        let client = try client { _ in
            XCTFail("Unapproved photos must not contact Immich")
            return [String: String]()
        }
        do {
            try await client.update(photo, assetID: UUID())
            XCTFail("Update was accepted before approval")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Approve"))
        }
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        try XCTUnwrap(request.httpBody)
    }

    private func client(handler: @escaping @Sendable (URLRequest) throws -> Any) throws -> ImmichClient {
        let load: @Sendable (URLRequest) throws -> (Data, URLResponse) = { request in
            let body = try JSONSerialization.data(withJSONObject: handler(request))
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url), statusCode: 200, httpVersion: "1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            return (body, response)
        }
        return try ImmichClient(
            server: XCTUnwrap(URL(string: "https://example.invalid")), apiKey: "test-key",
            load: { try load($0) }, sendFile: { request, file in
                XCTAssertGreaterThan(try Data(contentsOf: file).count, 3)
                return try load(request)
            },
            fingerprint: { _ in "test-checksum" }
        )
    }

    private func makePhoto() throws -> PhotoEntry {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data([0, 1, 2]).write(to: file)
        addTeardownBlock { try FileManager.default.removeItem(at: file) }
        var result = PhotoEntry(
            id: file.path, file: file, relativePath: file.lastPathComponent,
            revision: try FileRevision.read(file), existing: PhotoMetadata(), analysis: ImageAnalysis()
        )
        result.approved = true
        return result
    }
}

private final class AttachmentRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var attached = false

    var value: Bool { lock.withLock { attached } }
    func set() { lock.withLock { attached = true } }
}
