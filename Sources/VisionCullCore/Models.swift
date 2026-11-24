import Foundation

public enum WorkflowError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

public struct PhotoMetadata: Codable, Equatable, Sendable {
    public var subjects: [String]
    public var category: String
    public var description: String
    public var capturedAt: String
    public var latitude: Double?
    public var longitude: Double?
    public var topics: [String]
    public var moods: [String]
    public var styles: [String]
    public var rating: Int?

    public init(
        subjects: [String] = [], category: String = "", description: String = "",
        capturedAt: String = "", latitude: Double? = nil, longitude: Double? = nil,
        topics: [String] = [], moods: [String] = [], styles: [String] = [], rating: Int? = nil
    ) {
        self.subjects = subjects
        self.category = category
        self.description = description
        self.capturedAt = capturedAt
        self.latitude = latitude
        self.longitude = longitude
        self.topics = topics
        self.moods = moods
        self.styles = styles
        self.rating = rating
    }

    private enum CodingKeys: String, CodingKey {
        case subjects, category, description, capturedAt, latitude, longitude, topics, moods, styles, rating
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            subjects: try values.decode([String].self, forKey: .subjects),
            category: try values.decode(String.self, forKey: .category),
            description: try values.decode(String.self, forKey: .description),
            capturedAt: try values.decode(String.self, forKey: .capturedAt),
            latitude: try values.decodeIfPresent(Double.self, forKey: .latitude),
            longitude: try values.decodeIfPresent(Double.self, forKey: .longitude),
            topics: try values.decodeIfPresent([String].self, forKey: .topics) ?? [],
            moods: try values.decodeIfPresent([String].self, forKey: .moods) ?? [],
            styles: try values.decodeIfPresent([String].self, forKey: .styles) ?? [],
            rating: try values.decodeIfPresent(Int.self, forKey: .rating)
        )
    }

    public func validated() throws -> PhotoMetadata {
        var result = self
        result.subjects = Self.uniqueTags(subjects)
        for group in TagGroup.structured {
            let tags = Self.uniqueTags(self[keyPath: group.field])
            guard tags.allSatisfy({ !$0.contains("/") }) else {
                throw WorkflowError.message("Use comma-separated \(group.rawValue.lowercased()) without slashes.")
            }
            result[keyPath: group.field] = tags
        }
        if let rating, !(1...5).contains(rating) {
            throw WorkflowError.message("A star rating must be between 1 and 5.")
        }
        result.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        result.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        result.capturedAt = capturedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.capturedAt.isEmpty && !Self.isCaptureDate(result.capturedAt) {
            throw WorkflowError.message("Use an ISO date such as 2026-01-31 or 2026-01-31T14:30:00+01:00.")
        }
        switch (latitude, longitude) {
        case (nil, nil): break
        case let (lat?, lon?) where (-90...90).contains(lat) && (-180...180).contains(lon): break
        default: throw WorkflowError.message("Enter both GPS coordinates in decimal degrees.")
        }
        return result
    }

    public static func zonedDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func isCaptureDate(_ value: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}(?:T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)?)?$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return false }
        let day = String(value.prefix(10))
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day), formatter.string(from: date) == day else { return false }
        return true
    }

    public func proposed(using analysis: ImageAnalysis) -> PhotoMetadata {
        var proposal = self
        proposal.subjects = Self.uniqueTags(subjects + analysis.subjects)
        if topics.isEmpty { proposal.topics = analysis.topics ?? [] }
        if moods.isEmpty { proposal.moods = analysis.moods ?? [] }
        if styles.isEmpty { proposal.styles = analysis.styles ?? [] }
        if category.isEmpty { proposal.category = analysis.category }
        if description.isEmpty { proposal.description = analysis.description }
        return proposal
    }

    /// Keep user-confirmed tags portable between Immich and XMP.
    var structuredKeywords: [String] {
        TagGroup.structured.flatMap { group in
            self[keyPath: group.field].map { group.prefix + $0 }
        }
    }

    mutating func addKeyword(_ keyword: String) {
        for group in TagGroup.structured where keyword.hasPrefix(group.prefix) {
            let tag = String(keyword.dropFirst(group.prefix.count))
            if !tag.isEmpty && !tag.contains("/") {
                self[keyPath: group.field].append(tag)
                return
            }
        }
        subjects.append(keyword)
    }

    private static func uniqueTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

}

public enum TagGroup: String, CaseIterable, Codable, Sendable {
    case subjects = "Motifs"
    case topics = "Topics"
    case moods = "Moods"
    case styles = "Styles"

    static let structured: [Self] = [.topics, .moods, .styles]

    var prefix: String { "VisionCull/\(rawValue)/" }

    var field: WritableKeyPath<PhotoMetadata, [String]> {
        switch self {
        case .subjects: return \.subjects
        case .topics: return \.topics
        case .moods: return \.moods
        case .styles: return \.styles
        }
    }
}

public struct ImageAnalysis: Codable, Equatable, Sendable {
    public var subjects: [String]
    public var category: String
    public var description: String
    public var aestheticScore: Float?
    public var featurePrint: [Float]?
    public var topics: [String]?
    public var moods: [String]?
    public var styles: [String]?
    public var isUtility: Bool?
    public var appearance: ImageAppearance?

    public init(
        subjects: [String] = [], category: String = "", description: String = "",
        aestheticScore: Float? = nil, featurePrint: [Float]? = nil,
        topics: [String]? = nil, moods: [String]? = nil, styles: [String]? = nil,
        isUtility: Bool? = nil, appearance: ImageAppearance? = nil
    ) {
        self.subjects = subjects
        self.category = category
        self.description = description
        self.aestheticScore = aestheticScore
        self.featurePrint = featurePrint
        self.topics = topics
        self.moods = moods
        self.styles = styles
        self.isUtility = isUtility
        self.appearance = appearance
    }
}

public struct FileRevision: Codable, Equatable, Sendable {
    public let bytes: UInt64
    public let modified: Date
    public let statusChanged: Date?
    public let system: UInt64?
    public let inode: UInt64?

    public static func read(_ url: URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            throw WorkflowError.message("Expected a regular file: \(url.lastPathComponent)")
        }
        return Self(
            bytes: size.uint64Value, modified: modified,
            statusChanged: try url.resourceValues(forKeys: [.attributeModificationDateKey]).attributeModificationDate,
            system: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}

public struct PhotoEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let file: URL
    public let relativePath: String
    public let revision: FileRevision
    public let existing: PhotoMetadata
    public let analysis: ImageAnalysis
    public let fromApplePhotos: Bool
    public let immichSource: ImmichPhotoSource?
    public var metadata: PhotoMetadata
    public var approved: Bool
    public var seriesFavorite: Bool? = nil

    public init(
        id: String, file: URL, relativePath: String, revision: FileRevision,
        existing: PhotoMetadata, analysis: ImageAnalysis, fromApplePhotos: Bool = false, immichSource: ImmichPhotoSource? = nil
    ) {
        self.id = id
        self.file = file
        self.relativePath = relativePath
        self.revision = revision
        self.existing = existing
        self.analysis = analysis
        self.fromApplePhotos = fromApplePhotos
        self.immichSource = immichSource
        metadata = existing.proposed(using: analysis)
        approved = false
    }

    public var displayName: String {
        relativePath.split(separator: "/").last.map(String.init) ?? file.lastPathComponent
    }

    public func matchesSearch(_ query: String) -> Bool {
        matchesSearch(query, rules: TagRules())
    }

    func matchesSearch(_ query: String, rules: TagRules) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let tags = TagGroup.allCases.flatMap { group in
            metadata[keyPath: group.field].flatMap { rules.searchNames(for: $0, in: group) }
        }
        let fields = [relativePath, metadata.category, metadata.description] + tags
        return terms.allSatisfy { term in
            fields.contains { $0.localizedStandardContains(String(term)) }
        }
    }
}

public struct ScanIssue: Codable, Equatable, Sendable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public struct Review: Codable, Sendable {
    public var photos: [PhotoEntry]
    public var issues: [ScanIssue]
    public let analyzed: Int
    public let reused: Int

    public init(photos: [PhotoEntry], issues: [ScanIssue], analyzed: Int, reused: Int) {
        self.photos = photos
        self.issues = issues
        self.analyzed = analyzed
        self.reused = reused
    }

    public static func read(_ url: URL) throws -> Review {
        let result = try JSONDecoder().decode(Review.self, from: Data(contentsOf: url))
        guard Set(result.photos.map(\.id)).count == result.photos.count,
              result.photos.allSatisfy({ $0.file.isFileURL }) else {
            throw WorkflowError.message("The review contains duplicate photo IDs or nonlocal URLs.")
        }
        return result
    }

    public func write(_ url: URL, replacingReview: Bool = false) throws {
        guard url.pathExtension.lowercased() == "json" else {
            throw WorkflowError.message("Choose a .json file for the review.")
        }
        if replacingReview {
            _ = try FileRevision.read(url)
            _ = try Self.read(url)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: replacingReview ? .atomic : .withoutOverwriting)
    }
}
