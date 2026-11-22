import Foundation
#if os(macOS)
import Vision
#endif

public struct LocalVisionAnalyzer: PhotoAnalyzer {
    public let includeDuplicates: Bool

    public init(includeDuplicates: Bool = false) {
        self.includeDuplicates = includeDuplicates
    }

    public var cacheVersion: String {
        "vision-classification-1/\(ProcessInfo.processInfo.operatingSystemVersionString)/duplicates=\(includeDuplicates)"
    }

    public func analyze(_ file: URL) throws -> ImageAnalysis {
        #if os(macOS)
        return try autoreleasepool {
            let handler = VNImageRequestHandler(url: file)
            let classification = VNClassifyImageRequest()
            let aesthetic = VNCalculateImageAestheticsScoresRequest()
            let features = VNGenerateImageFeaturePrintRequest()
            var requests: [VNRequest] = [classification, aesthetic]
            if includeDuplicates { requests.append(features) }
            try handler.perform(requests)

            var seen = Set<String>()
            let labels = (classification.results ?? []).filter { $0.confidence >= 0.15 }
                .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
                .filter { seen.insert($0.lowercased()).inserted }
            let subjects = Array(labels.prefix(5))
            let category = Self.category(for: subjects)
            var vector: [Float]?
            if includeDuplicates, let feature = features.results?.first {
                switch feature.elementType {
                case .float:
                    vector = feature.data.withUnsafeBytes { raw in
                        stride(from: 0, to: raw.count, by: MemoryLayout<Float>.size)
                            .map { raw.loadUnaligned(fromByteOffset: $0, as: Float.self) }
                    }
                case .double:
                    vector = feature.data.withUnsafeBytes { raw in
                        stride(from: 0, to: raw.count, by: MemoryLayout<Double>.size)
                            .map { Float(raw.loadUnaligned(fromByteOffset: $0, as: Double.self)) }
                    }
                default: break
                }
            }
            return ImageAnalysis(
                subjects: subjects, category: category,
                description: subjects.isEmpty ? "" : "Photo showing " + subjects.prefix(3).joined(separator: ", ") + ".",
                aestheticScore: aesthetic.results?.first?.overallScore,
                featurePrint: vector
            )
        }
        #else
        throw WorkflowError.message("Apple Vision analysis is available on macOS 15 or later.")
        #endif
    }

    private static func category(for subjects: [String]) -> String {
        let rules = [
            ("People", ["person", "portrait", "human", "people"]),
            ("Plants", ["flower", "plant", "foliage", "bouquet", "tree"]),
            ("Animals", ["animal", "bird", "dog", "cat", "wildlife"]),
            ("Food", ["food", "dish", "meal", "fruit", "dessert"]),
            ("Architecture", ["building", "architecture", "interior", "city"]),
            ("Nature", ["outdoor", "mountain", "forest", "landscape", "beach", "water"]),
        ]
        let words = Set(subjects.flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) })
        return rules.first { !$0.1.allSatisfy { !words.contains($0) } }?.0 ?? (subjects.first ?? "")
    }
}

extension Review {
    /// Connected components of cosine-similar Vision observations, highest-scoring image first.
    public func duplicateGroups(minimumSimilarity: Double = 0.92) -> [[String]] {
        let samples: [(PhotoEntry, [Float])] = photos.compactMap { photo in
            guard let vector = photo.analysis.featurePrint, !vector.isEmpty else { return nil }
            let norm = sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 })
            guard norm.isFinite, norm > 0 else { return nil }
            return (photo, vector.map { $0 / norm })
        }
        var parents = Array(samples.indices)
        func root(_ index: Int) -> Int {
            var i = index
            while parents[i] != i {
                parents[i] = parents[parents[i]]
                i = parents[i]
            }
            return i
        }
        for i in samples.indices {
            for j in samples.indices.dropFirst(i + 1) {
                let lhs = samples[i].1
                let rhs = samples[j].1
                guard lhs.count == rhs.count else { continue }
                let similarity = zip(lhs, rhs).reduce(Float.zero) { $0 + $1.0 * $1.1 }
                if Double(similarity) >= minimumSimilarity {
                    let left = root(i)
                    let right = root(j)
                    parents[right] = left
                }
            }
        }
        let groups = Dictionary(grouping: samples.indices, by: root)
        return groups.keys.sorted().compactMap { key in
            guard let indices = groups[key], indices.count > 1 else { return nil }
            return indices.map { samples[$0].0 }.sorted {
                let lhs = $0.analysis.aestheticScore ?? -.infinity
                let rhs = $1.analysis.aestheticScore ?? -.infinity
                return lhs == rhs ? $0.id < $1.id : lhs > rhs
            }.map(\.id)
        }
    }
}
