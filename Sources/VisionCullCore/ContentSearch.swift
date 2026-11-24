import Foundation
#if os(macOS)
import NaturalLanguage
import Vision
#endif

public struct ContentHit: Sendable, Identifiable {
    public let photo: PhotoEntry
    public let score: Double
    public var id: String { photo.id }
}

public struct ContentMatches: Sendable {
    public let hits: [ContentHit]
    public let issues: [ScanIssue]
}

public struct ContentSearch: Sendable {
    let root: URL

    public init(root: URL = PhotoScanner.defaultCache) { self.root = root }

    /// Ranks untagged photos using local Vision concepts and, when installed, Apple's local language embeddings.
    public func text(_ query: String, in photos: [PhotoEntry], limit: Int = 50) throws -> ContentMatches {
        let terms = Self.terms(query)
        guard !terms.isEmpty, limit > 0 else { throw WorkflowError.message("Enter a description and a positive result limit.") }
        #if os(macOS)
        let embedding = NLEmbedding.wordEmbedding(for: .english)
        var embeddings = [String: [Double]]()
        func vector(_ word: String) -> [Double] {
            if let known = embeddings[word] { return known }
            let value = embedding?.vector(for: word) ?? []
            embeddings[word] = value
            return value
        }
        #endif
        var results = [ContentHit]()
        for photo in photos {
            try Task.checkCancellation()
            let image = photo.analysis
            let labels = image.subjects + [image.category] + (image.topics ?? [])
                + (image.moods ?? []) + (image.styles ?? [])
            let seen = Self.terms(labels.joined(separator: " "))
            guard !seen.isEmpty else { continue }
            let lexical = Double(terms.intersection(seen).count) / Double(terms.count)
            #if os(macOS)
            let expansions = terms.subtracting(seen).map { term -> Double in
                let reference = vector(term)
                guard !reference.isEmpty else { return 0 }
                let best = seen.compactMap { Self.cosine(reference, vector($0)) }.max() ?? 0
                return best >= 0.60 ? best * 0.65 : 0
            }
            let score = lexical + expansions.reduce(0, +) / Double(terms.count)
            #else
            let score = lexical
            #endif
            if score >= 0.20 { results.append(ContentHit(photo: photo, score: score)) }
        }
        return ContentMatches(hits: Self.ranked(results, limit: limit), issues: [])
    }

    public func image(_ reference: URL, in photos: [PhotoEntry], limit: Int = 50) throws -> ContentMatches {
        guard limit > 0 else { throw WorkflowError.message("Choose a positive result limit.") }
        #if os(macOS)
        let referenceRevision = try FileRevision.read(reference)
        let needle = try Self.printVector(reference)
        guard try FileRevision.read(reference) == referenceRevision else { throw WorkflowError.message("Reference image changed during analysis.") }
        let folder = root.appendingPathComponent("image-search", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var hits = [ContentHit]()
        var issues = [ScanIssue]()
        for photo in photos {
            try Task.checkCancellation()
            do {
                guard try FileRevision.read(photo.file) == photo.revision else {
                    throw WorkflowError.message("The image changed. Rescan it before searching.")
                }
                let printVector = try vector(for: photo, storedIn: folder, dimension: needle.count)
                guard let distance = Self.cosine(needle, printVector) else { continue }
                hits.append(ContentHit(photo: photo, score: distance))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.append(ScanIssue(path: photo.relativePath, message: error.localizedDescription))
            }
        }
        return ContentMatches(hits: Self.ranked(hits, limit: limit), issues: issues)
        #else
        throw WorkflowError.message("Reference-photo search uses Apple Vision on macOS.")
        #endif
    }

    #if os(macOS)
    private func vector(for photo: PhotoEntry, storedIn folder: URL, dimension: Int) throws -> [Double] {
        if let cached = photo.analysis.featurePrint, cached.count == dimension { return cached.map(Double.init) }
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        let file = folder.appendingPathComponent(PhotoScanner.cacheKey(photo.id + "\n" + version) + ".json")
        if let bytes = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(PrintCache.self, from: bytes),
           cached.id == photo.id, cached.revision == photo.revision, cached.vector.count == dimension {
            return cached.vector
        }
        let value = try Self.printVector(photo.file)
        guard try FileRevision.read(photo.file) == photo.revision else {
            throw WorkflowError.message("The image changed during analysis. Rescan it.")
        }
        let record = PrintCache(id: photo.id, revision: photo.revision, vector: value)
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
        return value
    }

    private static func printVector(_ url: URL) throws -> [Double] {
        try autoreleasepool {
            let request = VNGenerateImageFeaturePrintRequest()
            try VNImageRequestHandler(url: url, options: [:]).perform([request])
            guard let observation = request.results?.first, let vector = LocalVisionAnalyzer.featureVector(observation) else {
                throw WorkflowError.message("Apple Vision returned no feature print for this photo.")
            }
            return vector.map(Double.init)
        }
    }

    private struct PrintCache: Codable {
        let id: String
        let revision: FileRevision
        let vector: [Double]
    }
    #endif

    static func cosine(_ a: [Double], _ b: [Double]) -> Double? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        var dot = 0.0
        var aa = 0.0
        var bb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            aa += a[i] * a[i]
            bb += b[i] * b[i]
        }
        guard aa > 0, bb > 0 else { return nil }
        let score = dot / (sqrt(aa) * sqrt(bb))
        return score.isFinite ? max(-1, min(1, score)) : nil
    }

    private static func ranked(_ hits: [ContentHit], limit: Int) -> [ContentHit] {
        Array(hits.sorted { $0.score == $1.score ? $0.photo.relativePath < $1.photo.relativePath : $0.score > $1.score }.prefix(limit))
    }

    private static func terms(_ query: String) -> Set<String> {
        Set(TagRules.key(query).split(separator: " ").map(String.init).filter { !stop.contains($0) }
            .map { translations[$0] ?? $0 })
    }

    private static let stop = Set(["a", "an", "and", "at", "in", "the", "near", "after", "with",
                                   "ein", "eine", "im", "am", "in", "und", "mit", "bei", "nach", "der", "die", "das"])
    private static let translations = [
        "ruhig": "calm", "ruhige": "calm", "ruhiger": "calm", "stille": "calm",
        "strasse": "street", "strassen": "street", "regen": "rain", "regnerisch": "rain",
        "abendlicht": "sunset", "sonnenuntergang": "sunset", "daemmerung": "twilight", "dammerung": "twilight",
        "wald": "forest", "blume": "flower", "blumen": "flower", "garten": "garden", "mond": "moon",
        "gebirge": "mountain", "berg": "mountain", "berge": "mountain", "meer": "sea", "strand": "beach",
        "stadt": "city", "nacht": "night", "konzert": "concert", "hund": "dog", "katze": "cat",
        "person": "people", "menschen": "people", "portrat": "portrait", "dramatisch": "dramatic",
        "warme": "warm", "warmen": "warm", "farben": "colors", "blau": "blue",
    ]
}

extension Review {
    public func suggestedFavorite(in group: [String]) -> String? {
        let relevant = photos.filter { group.contains($0.id) }
        return relevant.first { $0.seriesFavorite == true }?.id ?? relevant.max {
            let first = $0.analysis.aestheticScore ?? -.infinity
            let second = $1.analysis.aestheticScore ?? -.infinity
            if first != second { return first < second }
            return ($0.analysis.appearance?.edgeDetail ?? 0) < ($1.analysis.appearance?.edgeDetail ?? 0)
        }?.id
    }

    public mutating func setFavorite(_ id: String, in group: [String]) {
        guard group.contains(id), photos.contains(where: { $0.id == id }) else { return }
        for i in photos.indices where group.contains(photos[i].id) {
            photos[i].seriesFavorite = photos[i].id == id
        }
    }
}
