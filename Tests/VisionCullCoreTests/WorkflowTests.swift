import Foundation
import XCTest
@testable import VisionCullCore

final class WorkflowTests: XCTestCase {
    func testRecursiveScanApprovalAndExportPreserveOriginalAndReuseAnalysis() throws {
        let root = try temporary()
        let source = root.appendingPathComponent("input")
        let nested = source.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let first = nested.appendingPathComponent("first.png")
        let second = source.appendingPathComponent("second.png")
        let original = try Data(contentsOf: fixture)
        try original.write(to: first)
        try original.write(to: second)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("alias.png"), withDestinationURL: first)

        let prior = PhotoMetadata(subjects: ["Original"], capturedAt: "2025-03-22T10:20:30", latitude: -52.5, longitude: 13.25)
        try XMP.document(for: prior).write(to: nested.appendingPathComponent("first.xmp"))
        let scanner = PhotoScanner(cacheRoot: root.appendingPathComponent("cache"), analyzer: FixedAnalyzer())
        var review = try scanner.scan(folder: source)
        XCTAssertTrue(review.issues.isEmpty)
        XCTAssertEqual(review.photos.map(\.relativePath), ["nested/first.png", "second.png"])
        XCTAssertEqual(review.analyzed, 2)
        XCTAssertEqual(review.photos[0].metadata.subjects, ["Original", "garden"])
        XCTAssertEqual(review.photos[0].metadata.capturedAt, prior.capturedAt)
        XCTAssertTrue(review.photos.allSatisfy { !$0.approved })

        XCTAssertThrowsError(try XMP.export(review, to: .alongside))
        review.photos[0].metadata.description = "Flowers & trees <3"
        review.photos[0].approved = true
        XCTAssertThrowsError(try XMP.export(review, to: .alongside))
        let output = root.appendingPathComponent("export")
        let urls = try XMP.export(review, to: .folder(output))
        XCTAssertEqual(urls.map(\.lastPathComponent), ["first.xmp"])
        XCTAssertEqual(try XMP.read(Data(contentsOf: urls[0])), review.photos[0].metadata)
        XCTAssertEqual(try XMP.export(review, to: .folder(output)), urls)
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("second.xmp").path))

        XCTAssertEqual(try scanner.scan(folder: source).reused, 2)
        try XMP.document(for: PhotoMetadata(subjects: ["New tag"])).write(to: nested.appendingPathComponent("first.xmp"))
        let sidecarEdit = try scanner.scan(folder: source)
        XCTAssertEqual(sidecarEdit.reused, 2)
        XCTAssertEqual(sidecarEdit.photos[0].metadata.subjects, ["New tag", "garden"])
        try Data([1, 2, 3]).write(to: first)
        let changed = try scanner.scan(folder: source)
        XCTAssertEqual(changed.reused, 1)
        XCTAssertEqual(changed.analyzed, 1)
        XCTAssertThrowsError(try XMP.export(review, to: .folder(output)))
    }

    func testExportRejectsSymlinkTraversalAndAmbiguousSibling() throws {
        let root = try temporary()
        let source = root.appendingPathComponent("input")
        let child = source.appendingPathComponent("child")
        let output = root.appendingPathComponent("output")
        let outside = root.appendingPathComponent("outside")
        for folder in [child, output, outside] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let first = child.appendingPathComponent("same.jpg")
        let second = child.appendingPathComponent("same.png")
        try FileManager.default.copyItem(at: fixture, to: first)
        try FileManager.default.copyItem(at: fixture, to: second)
        var review = try PhotoScanner(cacheRoot: root.appendingPathComponent("cache"), analyzer: FixedAnalyzer()).scan(folder: source)
        review.photos[0].approved = true
        XCTAssertThrowsError(try XMP.export(review, to: .alongside))
        XCTAssertThrowsError(try XMP.export(review, to: .folder(output)))
        try FileManager.default.removeItem(at: second)
        review.photos.removeLast()
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("child"), withDestinationURL: outside)
        XCTAssertThrowsError(try XMP.export(review, to: .folder(output)))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testXMPWithDateZoneAndGPSValidation() throws {
        let value = PhotoMetadata(
            subjects: ["Café", "café", "<tree>"], category: "Nature", description: "Flowers & trees",
            capturedAt: "2024-02-29T13:24:00.12+02:30", latitude: -90, longitude: 180
        )
        XCTAssertEqual(try XMP.read(XMP.document(for: value)), try value.validated())
        XCTAssertEqual(EmbeddedMetadata.exifDate("2024:02:29 13:24:00", offset: "+02:30"), "2024-02-29T13:24:00+02:30")
        XCTAssertNil(PhotoMetadata.zonedDate("2024-02-29T13:24:00"))
        XCTAssertThrowsError(try PhotoMetadata(capturedAt: "2023-02-29").validated())
        XCTAssertThrowsError(try PhotoMetadata(latitude: 20).validated())
        XCTAssertThrowsError(try XMP.document(for: PhotoMetadata(description: "\u{1}")))
    }

    #if os(macOS)
    func testAppleVisionRunsOnLocalFixture() throws {
        let result = try LocalVisionAnalyzer(includeDuplicates: true).analyze(fixture)
        XCTAssertNotNil(result.aestheticScore)
        XCTAssertFalse(try XCTUnwrap(result.featurePrint).isEmpty)
    }
    #endif

    private var fixture: URL {
        Bundle.module.url(forResource: "sample", withExtension: "png", subdirectory: "Fixtures")!
    }

    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
}

private struct FixedAnalyzer: PhotoAnalyzer {
    let cacheVersion = "test"
    func analyze(_ file: URL) throws -> ImageAnalysis {
        ImageAnalysis(subjects: ["garden"], category: "Nature", description: "Garden")
    }
}
