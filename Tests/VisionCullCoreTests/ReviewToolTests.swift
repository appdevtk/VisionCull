import Foundation
import XCTest
@testable import VisionCullCore

final class ReviewToolTests: XCTestCase {
    func testSavedSearchUsesCustomAliasesAndBatchEditResetsApproval() throws {
        let root = try temporary()
        let library = ReviewLibrary(root: root)
        try library.save(TagAlias(group: .moods, alias: "Filmlook", preferred: "Filmisch"))
        let query = ReviewFilterQuery(topics: ["Reise"], moods: ["Filmlook"], styles: ["Golden hour"], minimumStars: 4)
        try library.save(SavedSearch(name: "Abend", query: query))
        let preferences = try ReviewLibrary(root: root).read()
        XCTAssertEqual(preferences.searches.first?.query, query)
        var first = try photo("one", metadata: PhotoMetadata(topics: ["Travel"], moods: ["Cinematic"], styles: ["Abendlicht"], rating: 4))
        first.approved = true
        var second = try photo("two", metadata: first.metadata)
        second.metadata.rating = 3
        second.approved = true
        let review = Review(photos: [first, second], issues: [], analyzed: 2, reused: 0)
        let hits = query.matching(review.photos, aliases: preferences.aliases)
        XCTAssertEqual(hits.map(\.id), ["one"])
        XCTAssertEqual(ReviewFilterQuery(text: "Filmlook").matching(review.photos, aliases: preferences.aliases).count, 2)
        let edited = try BatchMetadataEdit(styles: ["Warm tones"], rating: 5).applying(to: review, ids: Set(hits.map(\.id)))
        XCTAssertEqual(edited.photos[0].metadata.styles, ["Abendlicht", "Warm tones"])
        XCTAssertEqual(edited.photos[0].metadata.rating, 5)
        XCTAssertFalse(edited.photos[0].approved)
        XCTAssertEqual(edited.photos[1], second)
        XCTAssertThrowsError(try BatchMetadataEdit(moods: ["invalid/tag"]).applying(to: review, ids: ["one"]))
    }

    func testAliasInventoryDetectsDuplicatesAndCycleDoesNotPersist() throws {
        let root = try temporary()
        let library = ReviewLibrary(root: root)
        try library.save(TagAlias(group: .moods, alias: "Filmlook", preferred: "Filmisch"))
        try library.save(TagAlias(group: .styles, alias: "Copper", preferred: "Rust"))
        XCTAssertThrowsError(try library.save(TagAlias(group: .styles, alias: "Rust", preferred: "Copper")))
        let preferences = try library.read()
        XCTAssertEqual(preferences.aliases.count, 2)
        let photos = [
            try photo("one", metadata: PhotoMetadata(moods: ["Filmlook", "Filmisch"], styles: ["Abendlicht", "Abendlict"])),
            try photo("two", metadata: PhotoMetadata(styles: ["Rust"])),
        ]
        let matches = TagInventory.similar(in: photos, aliases: preferences.aliases)
        XCTAssertTrue(matches.contains { Set([$0.first, $0.second]) == Set(["Filmlook", "Filmisch"]) })
        XCTAssertTrue(matches.contains { Set([$0.first, $0.second]) == Set(["Abendlicht", "Abendlict"]) })
        let review = Review(photos: photos, issues: [], analyzed: 2, reused: 0)
        let approved = try TagVocabulary(root: root).approve(review, ids: ["one"])
        XCTAssertEqual(approved.photos[0].metadata.moods, ["Filmisch"])
    }

    func testDescriptionSearchUsesVisionAnalysisAndGermanConcepts() throws {
        let city = try photo("city", analysis: ImageAnalysis(subjects: ["street", "rain"], moods: ["Calm"]))
        let garden = try photo("garden", analysis: ImageAnalysis(subjects: ["flower", "garden"]))
        let results = try ContentSearch().text("ruhige Straße nach Regen", in: [garden, city], limit: 1)
        XCTAssertEqual(results.hits.map(\.id), ["city"])
        XCTAssertEqual(results.hits.first?.score, 1)
        XCTAssertThrowsError(try ContentSearch().text("  ", in: [city]))
        XCTAssertEqual(ContentSearch.cosine([1, 0], [0, 1]), 0)
        XCTAssertNil(ContentSearch.cosine([1, 0], [1]))
    }

    func testSeriesFavoriteAndRelativeEdgeDetail() throws {
        var review = Review(photos: [
            try photo("first", analysis: ImageAnalysis(aestheticScore: 0.9)),
            try photo("second", analysis: ImageAnalysis(aestheticScore: 0.4)),
            try photo("other", analysis: ImageAnalysis(aestheticScore: 1.0)),
        ], issues: [], analyzed: 3, reused: 0)
        XCTAssertEqual(review.suggestedFavorite(in: ["first", "second"]), "first")
        review.setFavorite("second", in: ["first", "second"])
        XCTAssertEqual(review.suggestedFavorite(in: ["first", "second"]), "second")
        XCTAssertNil(review.photos[2].seriesFavorite)
        let roundTrip = try JSONDecoder().decode(Review.self, from: JSONEncoder().encode(review))
        XCTAssertEqual(roundTrip.suggestedFavorite(in: ["first", "second"]), "second")
        let flat = Array(repeating: [UInt8](arrayLiteral: 50, 50, 50, 255), count: 9).flatMap { $0 }
        var edged = flat
        edged[16...18] = [255, 255, 255]
        XCTAssertEqual(ImageAppearance.measure(premultipliedRGBA: flat, width: 3)?.edgeDetail, 0)
        XCTAssertGreaterThan(ImageAppearance.measure(premultipliedRGBA: edged, width: 3)?.edgeDetail ?? 0, 1)
    }

    #if os(macOS)
    func testReferenceImageSearchUsesLocalVisionAndCache() throws {
        let root = try temporary()
        let entry = try photo("image")
        let search = ContentSearch(root: root)
        let match = try search.image(fixture, in: [entry])
        XCTAssertEqual(match.hits.first?.photo.id, entry.id)
        XCTAssertEqual(try XCTUnwrap(match.hits.first?.score), 1, accuracy: 0.0001)
        XCTAssertTrue(match.issues.isEmpty)
        XCTAssertEqual(try search.image(fixture, in: [entry]).hits.map(\.id), [entry.id])
        let cache = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("image-search").path)
        XCTAssertEqual(cache.count, 1)
    }
    #endif

    private var fixture: URL {
        Bundle.module.url(forResource: "sample", withExtension: "png", subdirectory: "Fixtures")!
    }

    private func photo(_ id: String, metadata: PhotoMetadata = PhotoMetadata(), analysis: ImageAnalysis = ImageAnalysis()) throws -> PhotoEntry {
        PhotoEntry(id: id, file: fixture, relativePath: id + ".png", revision: try FileRevision.read(fixture), existing: metadata, analysis: analysis)
    }

    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}
