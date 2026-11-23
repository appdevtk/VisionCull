import Foundation
import XCTest
#if os(macOS)
import ImageIO
import UniformTypeIdentifiers
#endif
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

        let aliasedRoot = root.appendingPathComponent("selected-folder")
        try FileManager.default.createSymbolicLink(at: aliasedRoot, withDestinationURL: source)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("out-of-tree"), withDestinationURL: fixture.deletingLastPathComponent()
        )
        let prior = PhotoMetadata(subjects: ["Original"], capturedAt: "2025-03-22T10:20:30", latitude: -52.5, longitude: 13.25)
        try XMP.document(for: prior).write(to: nested.appendingPathComponent("first.xmp"))
        let scanner = PhotoScanner(cacheRoot: root.appendingPathComponent("cache"), analyzer: FixedAnalyzer())
        var review = try scanner.scan(folder: aliasedRoot)
        XCTAssertTrue(review.issues.isEmpty, "\(review.issues)")
        XCTAssertEqual(review.photos.map(\.relativePath), ["nested/first.png", "second.png"])
        guard review.photos.count == 2 else { return }
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

    func testSearchMetadataRoundTripsAndReadsLegacyReviews() throws {
        let legacy = Data(#"{"subjects":["flowery"],"category":"Plants","description":"","capturedAt":""}"#.utf8)
        let older = try JSONDecoder().decode(PhotoMetadata.self, from: legacy)
        XCTAssertEqual(older, PhotoMetadata(subjects: ["flowery"], category: "Plants"))
        let olderExport = try XMP.read(XMP.document(for: older))
        XCTAssertEqual(olderExport, older)

        let approved = try PhotoMetadata(
            subjects: ["Tulips"], description: "Pale pink blossoms",
            topics: [" Frühling & Garten ", "frühling & garten"], moods: ["Calm"], styles: ["Soft contrast"], rating: 4
        ).validated()
        let encoded = try XMP.document(for: approved)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("VisionCull/Topics/Frühling &amp; Garten"))
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("<xmp:Rating>4</xmp:Rating>"))
        XCTAssertEqual(try XMP.read(encoded), approved)
        let ratingAttribute = Data("""
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:stars="http://ns.adobe.com/xap/1.0/">
          <rdf:Description stars:Rating="3"/>
        </rdf:RDF>
        """.utf8)
        XCTAssertEqual(try XMP.read(ratingAttribute).rating, 3)
        XCTAssertEqual(try JSONDecoder().decode(PhotoMetadata.self, from: JSONEncoder().encode(approved)), approved)
        var entry = PhotoEntry(
            id: "sample", file: fixture, relativePath: "weekend/sample.png", revision: try FileRevision.read(fixture),
            existing: approved, analysis: ImageAnalysis(topics: ["New topic"], moods: ["Dramatic"], styles: ["Dark"])
        )
        XCTAssertEqual(entry.metadata, approved)
        XCTAssertTrue(entry.matchesSearch("fruhling CALM pink"))
        XCTAssertFalse(entry.matchesSearch("fruhling dramatic"))
        entry.metadata.moods = ["Dramatic"]
        XCTAssertTrue(entry.matchesSearch("fruhling dramatic"))
        XCTAssertThrowsError(try PhotoMetadata(topics: ["a/b"]).validated())
        XCTAssertThrowsError(try PhotoMetadata(rating: 6).validated())
    }

    func testAppearanceMeasuresTonesAndSkipsTransparentPixels() throws {
        let black: [UInt8] = [0, 0, 0, 255]
        var lowKey = Array(repeating: black, count: 8).flatMap { $0 }
        lowKey += [255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0]
        let dramatic = try XCTUnwrap(ImageAppearance.measure(premultipliedRGBA: lowKey))
        XCTAssertEqual(dramatic.brightness, 0.2, accuracy: 0.0001)
        XCTAssertEqual(dramatic.contrast, 1, accuracy: 0.0001)
        XCTAssertEqual(dramatic.shadowFraction, 0.8)
        XCTAssertEqual(dramatic.highlightFraction, 0.2)
        XCTAssertEqual(dramatic.palette, ["#000000", "#FFFFFF"])
        XCTAssertEqual(dramatic.moodSuggestions, ["Dramatic"])
        XCTAssertTrue(dramatic.styleSuggestions.contains("Near monochrome"))
        let calm = try XCTUnwrap(ImageAppearance.measure(premultipliedRGBA: [100, 100, 100, 255]))
        XCTAssertEqual(calm.moodSuggestions, ["Calm"])
        XCTAssertNil(ImageAppearance.measure(premultipliedRGBA: [0, 0, 0, 0]))
        XCTAssertEqual(
            LocalVisionAnalyzer.topics(for: ["concert_stage", "forest path", "city building"]),
            ["Music & performance", "Nature & outdoors", "Cities & architecture"]
        )
        let proposed = PhotoMetadata().proposed(using: ImageAnalysis(
            topics: ["Music & performance"], moods: dramatic.moodSuggestions, styles: dramatic.styleSuggestions
        ))
        XCTAssertEqual(proposed.topics, ["Music & performance"])
        XCTAssertEqual(proposed.moods, ["Dramatic"])
        XCTAssertNil(proposed.rating)
    }

    #if os(macOS)
    func testAppleVisionRunsOnLocalFixture() throws {
        let result = try LocalVisionAnalyzer(includeDuplicates: true).analyze(fixture)
        XCTAssertNotNil(result.aestheticScore)
        XCTAssertNotNil(result.isUtility)
        XCTAssertFalse(try XCTUnwrap(result.featurePrint).isEmpty)
        let appearance = try XCTUnwrap(result.appearance)
        XCTAssertGreaterThan(appearance.brightness, 0.25)
        XCTAssertGreaterThan(appearance.saturation, 0.2)
        XCTAssertEqual(appearance.palette.count, 3)
    }

    func testImageIOReadsEmbeddedCaptureMetadata() throws {
        let root = try temporary()
        let photo = root.appendingPathComponent("original.jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(fixture as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let exif: [String: Any] = [kCGImagePropertyExifDateTimeOriginal as String: "2024:02:29 07:30:00"]
        let gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: 48.25, kCGImagePropertyGPSLatitudeRef as String: "N",
            kCGImagePropertyGPSLongitude as String: 16.5, kCGImagePropertyGPSLongitudeRef as String: "W"
        ]
        CGImageDestinationAddImage(writer, image, [
            kCGImagePropertyExifDictionary as String: exif, kCGImagePropertyGPSDictionary as String: gps,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let metadata = try EmbeddedMetadata.read(PhotoInput(id: "image", file: photo, relativePath: "original.jpg"))
        XCTAssertEqual(metadata.capturedAt, "2024-02-29T07:30:00")
        XCTAssertEqual(metadata.latitude, 48.25)
        XCTAssertEqual(metadata.longitude, -16.5)
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
