import Foundation

public protocol PhotoAnalyzer: Sendable {
    var cacheVersion: String { get }
    func analyze(_ file: URL) throws -> ImageAnalysis
}

public struct PhotoInput: Sendable {
    public let id: String
    public let file: URL
    public let relativePath: String
    public let libraryMetadata: PhotoMetadata?

    public init(id: String, file: URL, relativePath: String, libraryMetadata: PhotoMetadata? = nil) {
        self.id = id
        self.file = file
        self.relativePath = relativePath
        self.libraryMetadata = libraryMetadata
    }
}

public struct PhotoScanner: Sendable {
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "avif",
        "dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "pef"
    ]

    public static var defaultCache: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VisionCull", isDirectory: true)
    }

    public let cacheRoot: URL
    public let analyzer: any PhotoAnalyzer

    public init(cacheRoot: URL = PhotoScanner.defaultCache, analyzer: any PhotoAnalyzer = LocalVisionAnalyzer()) {
        self.cacheRoot = cacheRoot
        self.analyzer = analyzer
    }

    public func scan(folder: URL) throws -> Review {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw WorkflowError.message("Choose a readable photo folder.")
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        var issues = [ScanIssue]()
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                issues.append(ScanIssue(path: url.path, message: error.localizedDescription))
                return true
            }
        ) else { throw WorkflowError.message("Unable to enumerate \(root.path).") }

        let excluded = cacheRoot.standardizedFileURL.resolvingSymlinksInPath().path
        var inputs = [PhotoInput]()
        for case let file as URL in files {
            try Task.checkCancellation()
            if file.path == excluded {
                files.skipDescendants()
                continue
            }
            do {
                let values = try file.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true {
                    files.skipDescendants()
                } else if values.isRegularFile == true, Self.imageExtensions.contains(file.pathExtension.lowercased()) {
                    let relative = file.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
                    inputs.append(PhotoInput(id: file.path, file: file, relativePath: relative))
                }
            } catch {
                issues.append(ScanIssue(path: file.path, message: error.localizedDescription))
            }
        }
        var review = try inspect(inputs.sorted { $0.relativePath < $1.relativePath })
        review.issues.insert(contentsOf: issues, at: 0)
        return review
    }

    public func inspect(_ inputs: [PhotoInput]) throws -> Review {
        let cache = cacheRoot.appendingPathComponent("analysis", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var entries = [PhotoEntry]()
        var issues = [ScanIssue]()
        var analyzed = 0
        var reused = 0

        for input in inputs {
            try Task.checkCancellation()
            do {
                let revision = try FileRevision.read(input.file)
                let version = analyzer.cacheVersion
                let file = cache.appendingPathComponent(Self.cacheKey(input.id + "\n" + version) + ".json")
                let previous = try? JSONDecoder().decode(CacheRecord.self, from: Data(contentsOf: file))
                let existing = try EmbeddedMetadata.read(input)
                let analysis: ImageAnalysis
                if let previous, previous.id == input.id, previous.revision == revision,
                   previous.version == version {
                    guard try FileRevision.read(input.file) == revision else {
                        throw WorkflowError.message("Image changed during metadata inspection. Rescan it.")
                    }
                    analysis = previous.analysis
                    reused += 1
                } else {
                    analysis = try analyzer.analyze(input.file)
                    guard try FileRevision.read(input.file) == revision else {
                        throw WorkflowError.message("Image changed during analysis. Rescan it.")
                    }
                    let record = CacheRecord(id: input.id, revision: revision, version: version, analysis: analysis)
                    try JSONEncoder().encode(record).write(to: file, options: .atomic)
                    analyzed += 1
                }
                entries.append(PhotoEntry(
                    id: input.id, file: input.file, relativePath: input.relativePath, revision: revision,
                    existing: existing, analysis: analysis, fromApplePhotos: input.libraryMetadata != nil
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.append(ScanIssue(path: input.relativePath, message: error.localizedDescription))
            }
        }
        return Review(photos: entries, issues: issues, analyzed: analyzed, reused: reused)
    }

    private struct CacheRecord: Codable {
        let id: String
        let revision: FileRevision
        let version: String
        let analysis: ImageAnalysis
    }

    // The full ID is checked in the record. A hash collision can only cause a cache miss.
    private static func cacheKey(_ id: String) -> String {
        let hash = id.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}
