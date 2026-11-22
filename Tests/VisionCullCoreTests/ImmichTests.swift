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
            let body = try XCTUnwrap(request.httpBody)
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
                let data = try XCTUnwrap(request.httpBody)
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

    func testPendingPhotoIsRejectedBeforeRequest() async throws {
        var photo = try makePhoto()
        photo.approved = false
        let client = try client { _ in
            XCTFail("Unapproved photos must not contact Immich")
            return [:]
        }
        do {
            try await client.update(photo, assetID: UUID())
            XCTFail("Update was accepted before approval")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Approve"))
        }
    }

    private func client(handler: @escaping (URLRequest) throws -> [String: Any]) throws -> ImmichClient {
        StubProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return try ImmichClient(
            server: XCTUnwrap(URL(string: "https://example.invalid")), apiKey: "test-key",
            session: URLSession(configuration: configuration), fingerprint: { _ in "test-checksum" }
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

private final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> [String: Any])?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let data = try JSONSerialization.data(withJSONObject: handler(request))
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: "1.1",
                                                        headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
