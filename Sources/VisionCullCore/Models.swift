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

    public init(
        subjects: [String] = [], category: String = "", description: String = "",
        capturedAt: String = "", latitude: Double? = nil, longitude: Double? = nil
    ) {
        self.subjects = subjects
        self.category = category
        self.description = description
        self.capturedAt = capturedAt
        self.latitude = latitude
        self.longitude = longitude
    }

    public func validated() throws -> PhotoMetadata {
        var result = self
        var keys = Set<String>()
        result.subjects = subjects.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && keys.insert($0.lowercased()).inserted }
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
        var seen = Set(subjects.map { $0.lowercased() })
        proposal.subjects += analysis.subjects.filter { seen.insert($0.lowercased()).inserted }
        if category.isEmpty { proposal.category = analysis.category }
        if description.isEmpty { proposal.description = analysis.description }
        return proposal
    }
}

public struct ImageAnalysis: Codable, Equatable, Sendable {
    public var subjects: [String]
    public var category: String
    public var description: String
    public var aestheticScore: Float?
    public var featurePrint: [Float]?

    public init(
        subjects: [String] = [], category: String = "", description: String = "",
        aestheticScore: Float? = nil, featurePrint: [Float]? = nil
    ) {
        self.subjects = subjects
        self.category = category
        self.description = description
        self.aestheticScore = aestheticScore
        self.featurePrint = featurePrint
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
    public var metadata: PhotoMetadata
    public var approved: Bool

    public init(
        id: String, file: URL, relativePath: String, revision: FileRevision,
        existing: PhotoMetadata, analysis: ImageAnalysis, fromApplePhotos: Bool = false
    ) {
        self.id = id
        self.file = file
        self.relativePath = relativePath
        self.revision = revision
        self.existing = existing
        self.analysis = analysis
        self.fromApplePhotos = fromApplePhotos
        metadata = existing.proposed(using: analysis)
        approved = false
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
