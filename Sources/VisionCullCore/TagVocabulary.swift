import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif

struct TagRules {
    struct Match {
        let name: String
        let existing: Bool
    }

    // The first name is the default only when the vocabulary has no equivalent.
    private static let aliases: [TagGroup: [[String]]] = [
        .subjects: [
            ["Flowers", "Blumen", "Flower", "Blume"],
            ["Street photography", "Straßenfotografie", "Street photo"],
            ["Sunset", "Sonnenuntergang"],
        ],
        .topics: [
            ["Travel", "Reise", "Reisen", "Urlaub", "Travel photography"],
            ["Celebrations", "Feiern", "Feste"],
            ["Nature & outdoors", "Natur", "Natur & Outdoor", "Outdoors"],
            ["Flowers & gardens", "Blumen & Gärten", "Blumen und Gärten"],
            ["Food & drink", "Essen & Trinken", "Essen und Trinken"],
            ["People & portraits", "Menschen & Porträts", "Menschen und Porträts"],
            ["Cities & architecture", "Stadt & Architektur", "Städte & Architektur"],
            ["Night & twilight", "Nacht & Dämmerung", "Nacht und Dämmerung"],
        ],
        .moods: [
            ["Calm", "Ruhig", "Ruhe", "Friedlich", "Peaceful", "Serene", "Quiet", "Stille"],
            ["Dramatic", "Dramatisch", "Drama"],
            ["Lively", "Lebhaft", "Lebendig", "Energetic"],
            ["Subdued", "Gedämpft", "Zurückhaltend"],
            ["Cinematic", "Filmisch", "Cinematisch", "Kinematografisch"],
            ["Dreamy", "Verträumt", "Traumhaft"],
            ["Melancholic", "Melancholisch", "Melancholy"],
        ],
        .styles: [
            ["Golden hour", "Abendlicht", "Warmes Abendlicht", "Goldene Stunde"],
            ["Warm tones", "Warme Töne", "Warme Farben"],
            ["Cool tones", "Kühle Töne", "Kühle Farben"],
            ["High contrast", "Hoher Kontrast", "Kontrastreich"],
            ["Soft contrast", "Weicher Kontrast", "Kontrastarm"],
            ["Near monochrome", "Fast monochrom"],
            ["Monochrome", "Monochrom", "Schwarzweiß", "Black and white", "B&W"],
            ["Vivid colors", "Kräftige Farben", "Satte Farben"],
            ["Muted colors", "Gedämpfte Farben", "Blasse Farben"],
            ["Bright", "Hell", "Helles Bild"],
            ["Dark", "Dunkel", "Dunkles Bild"],
        ],
    ]

    static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "ß", with: "ss")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    private static let families: [TagGroup: [String: String]] = aliases.mapValues { lists in
        Dictionary(lists.flatMap { list in list.map { (key($0), list[0]) } }, uniquingKeysWith: { first, _ in first })
    }

    private let custom: [TagAlias]
    private let byGroup: [TagGroup: [String: String]]

    init(custom: [TagAlias] = []) {
        self.custom = custom
        byGroup = Dictionary(grouping: custom, by: \.group).mapValues { rules in
            Dictionary(rules.map { (Self.baseKey($0.alias, in: $0.group), $0.preferred) }, uniquingKeysWith: { _, last in last })
        }
    }

    static func baseKey(_ name: String, in group: TagGroup) -> String {
        let normalized = key(name)
        return families[group]?[normalized].map(key) ?? normalized
    }

    static func validate(custom: [TagAlias]) throws {
        let rules = TagRules(custom: custom)
        for entry in custom {
            if rules.customName(entry.alias, in: entry.group) == nil {
                throw WorkflowError.message("The alias for \(entry.alias) creates a cycle.")
            }
        }
    }

    /// A nil result is a cycle. A preference within the same built-in family is a spelling choice.
    private func customName(_ name: String, in group: TagGroup) -> String? {
        let values = byGroup[group] ?? [:]
        var current = name
        var seen = Set<String>()
        while let preferred = values[Self.baseKey(current, in: group)] {
            let key = Self.baseKey(current, in: group)
            if Self.baseKey(preferred, in: group) == key { return preferred }
            guard seen.insert(key).inserted else { return nil }
            current = preferred
        }
        return current
    }

    private func canonicalName(_ name: String, in group: TagGroup) -> String {
        let preferred = customName(name, in: group) ?? name
        if byGroup[group]?[Self.baseKey(name, in: group)] != nil { return preferred }
        return Self.families[group]?[Self.key(name)] ?? name
    }

    func searchNames(for name: String, in group: TagGroup) -> [String] {
        let candidates = (Self.aliases[group] ?? []).flatMap { $0 }
            + custom.filter { $0.group == group }.flatMap { [$0.alias, $0.preferred] }
        return [name] + candidates.filter { equivalent(name, $0, in: group) }
    }

    static func pathKey(_ value: String) -> String {
        value.split(separator: "/", omittingEmptySubsequences: false).map { part in
            let value = String(part)
            let normalized = key(value)
            return normalized.isEmpty ? value.lowercased() : normalized
        }.joined(separator: "/")
    }

    func identity(_ name: String, in group: TagGroup) -> String {
        let key = Self.baseKey(canonicalName(name, in: group), in: group)
        return key.isEmpty ? "literal:" + name : "normalized:" + key
    }

    func equivalent(_ first: String, _ second: String, in group: TagGroup) -> Bool {
        identity(first, in: group) == identity(second, in: group)
    }

    func resolve(_ proposed: String, in group: TagGroup, candidates: [String], enforceUserPreference: Bool = false) throws -> Match {
        if proposed.contains("/") {
            if let match = candidates.first(where: { Self.pathKey(proposed) == Self.pathKey($0) }) {
                return Match(name: match, existing: true)
            }
            return Match(name: proposed, existing: false)
        }
        let normalized = canonicalName(proposed, in: group)
        if enforceUserPreference, let preferred = custom.first(where: {
            $0.group == group && self.equivalent(proposed, $0.preferred, in: group)
        }).flatMap({ customName($0.preferred, in: group) }) {
            return Match(name: preferred, existing: candidates.contains(preferred))
        }
        let equivalent = candidates.filter { !$0.contains("/") && self.equivalent(proposed, $0, in: group) }
        let userPreference = Self.key(customName(proposed, in: group) ?? proposed)
        let hasPreference = byGroup[group]?[Self.baseKey(proposed, in: group)] != nil
        let preferred = hasPreference ? equivalent.first { Self.key($0) == userPreference } : nil
        if let match = preferred ?? equivalent.first {
            return Match(name: match, existing: true)
        }

        var near = [String]()
        for candidate in candidates where !candidate.contains("/") && Self.isTypo(Self.key(proposed), Self.key(candidate)) {
            if !near.contains(where: { self.equivalent(candidate, $0, in: group) }) { near.append(candidate) }
        }
        if near.count > 1 {
            throw WorkflowError.message(
                "“\(proposed)” has several similar \(group.rawValue.lowercased()): \(near.sorted().joined(separator: ", ")). Choose an existing tag."
            )
        }
        if let match = near.first { return Match(name: match, existing: true) }
        return Match(name: normalized, existing: false)
    }

    /// Allow one inserted or missing letter or an adjacent transposition in longer names.
    /// A substitution can change the meaning of an otherwise valid tag.
    static func isTypo(_ first: String, _ second: String) -> Bool {
        let a = Array(first)
        let b = Array(second)
        if min(a.count, b.count) < 6 || abs(a.count - b.count) > 1 { return false }
        if a.count == b.count {
            let different = a.indices.filter { a[$0] != b[$0] }
            guard different.count == 2, different[1] == different[0] + 1 else { return false }
            let (x, y) = (different[0], different[1])
            return a[x] != " " && a[y] != " " && a[x] == b[y] && a[y] == b[x]
        }
        let (long, short) = a.count > b.count ? (a, b) : (b, a)
        if let i = short.indices.first(where: { short[$0] != long[$0] }) {
            return long[i] != " " && long.dropFirst(i + 1).elementsEqual(short.dropFirst(i))
        }
        return long.last != " "
    }
}

public struct TagVocabulary: Sendable {
    public let root: URL

    public init(root: URL = PhotoScanner.defaultCache) {
        self.root = root
    }

    /// Reuses prior labels on new scans. Known labels on a source photo take precedence over learned suggestions.
    func propose(for entries: [PhotoEntry]) throws -> [PhotoEntry] {
        let rules = TagRules(custom: try ReviewLibrary(root: root).read().aliases)
        let profile = try read()
        let approved = profile.examples.keys.sorted().compactMap { profile.examples[$0] }
        let vocabulary = makeVocabulary(approved: approved.map(\.labels), sources: entries.map { Labels($0.existing) })
        return try entries.map { entry in
            try Task.checkCancellation()
            var result = entry
            let evidence = Labels(entry.analysis)
            for group in TagGroup.allCases {
                let original = entry.existing[keyPath: group.field]
                let proposed = entry.metadata[keyPath: group.field]
                let personal = original.isEmpty ? recommendations(in: group, for: evidence, from: approved) : []
                let subjective = group == .moods || group == .styles
                let values = subjective && !personal.isEmpty ? personal : proposed + personal
                result.metadata[keyPath: group.field] = canonical(values, in: group, vocabulary: vocabulary[group] ?? [], rules: rules)
            }
            return result
        }
    }

    /// Resolve the entire batch before saving the review or updating what has been learned.
    public func approve(_ review: Review, ids: Set<String>, save: (Review) throws -> Void = { _ in }) throws -> Review {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = try FileAccessLock(url: root.appendingPathComponent("tag-vocabulary.lock"))
        defer { withExtendedLifetime(lock) {} }
        var profile = try read()
        let rules = TagRules(custom: try ReviewLibrary(root: root).read().aliases)
        var updated = review
        let ordered = profile.examples.keys.sorted().compactMap { profile.examples[$0]?.labels }
        let existing = review.photos.flatMap { photo in
            photo.approved && !ids.contains(photo.id) ? [Labels(photo.metadata), Labels(photo.existing)] : [Labels(photo.existing)]
        }
        var vocabulary = makeVocabulary(approved: ordered, sources: existing)

        for i in updated.photos.indices where ids.contains(updated.photos[i].id) {
            var photo = updated.photos[i]
            var metadata = try photo.metadata.validated()
            for group in TagGroup.allCases {
                var seen = Set<String>()
                let tags = metadata[keyPath: group.field]
                var resolved = [String]()
                for tag in tags {
                    let available = vocabulary[group] ?? []
                    do {
                        let match = try rules.resolve(tag, in: group, candidates: available, enforceUserPreference: true)
                        if seen.insert(match.name.lowercased()).inserted { resolved.append(match.name) }
                        if !match.existing { vocabulary[group, default: []].append(match.name) }
                    } catch {
                        throw WorkflowError.message("\(photo.relativePath): \(error.localizedDescription)")
                    }
                }
                metadata[keyPath: group.field] = resolved
            }
            photo.metadata = metadata
            photo.approved = true
            updated.photos[i] = photo
            profile.examples[photo.id] = Example(labels: Labels(metadata), evidence: Labels(photo.analysis))
        }

        try save(updated)
        try write(profile)
        return updated
    }

    public func forget(_ photoID: String) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let lock = try FileAccessLock(url: root.appendingPathComponent("tag-vocabulary.lock"))
        defer { withExtendedLifetime(lock) {} }
        var profile = try read()
        if profile.examples.removeValue(forKey: photoID) != nil { try write(profile) }
    }

    private func write(_ profile: Profile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(profile).write(to: file, options: .atomic)
    }

    private func canonical(_ tags: [String], in group: TagGroup, vocabulary: [String], rules: TagRules) -> [String] {
        var available = vocabulary
        var seen = Set<String>()
        return tags.compactMap { input in
            let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let match = try? rules.resolve(name, in: group, candidates: available, enforceUserPreference: true)
            let result = match?.name ?? name // Retain ambiguous input so approval can ask the reviewer.
            if match?.existing == false { available.append(result) }
            return seen.insert(result.lowercased()).inserted ? result : nil
        }
    }

    private func recommendations(in group: TagGroup, for evidence: Labels, from examples: [Example]) -> [String] {
        let signal = Set(evidence.values(for: group))
        guard !signal.isEmpty else { return [] }
        var counts = [String: Int]()
        var comparable = 0
        for example in examples {
            let other = Set(example.evidence.values(for: group))
            let shared = signal.intersection(other)
            guard !shared.isEmpty, shared.count * 2 >= signal.union(other).count else { continue }
            comparable += 1
            for tag in Set(example.labels.values(for: group)) { counts[tag, default: 0] += 1 }
        }
        let supported = counts.filter { $0.value >= 2 && $0.value * 3 >= comparable * 2 }
        return supported.sorted { first, second in
            first.value == second.value ? first.key < second.key : first.value > second.value
        }.prefix(4).map(\.key)
    }

    private func makeVocabulary(approved: [Labels], sources: [Labels]) -> [TagGroup: [String]] {
        Dictionary(uniqueKeysWithValues: TagGroup.allCases.map { group in
            var seen = Set<String>()
            let values = (approved + sources).flatMap { $0.values(for: group) }
            return (group, values.filter { seen.insert($0).inserted })
        })
    }

    private var file: URL { root.appendingPathComponent("tag-vocabulary.json") }

    private func read() throws -> Profile {
        do { return try JSONDecoder().decode(Profile.self, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return Profile() }
    }

    private struct Profile: Codable {
        var examples: [String: Example] = [:]
    }

    private struct Example: Codable {
        let labels: Labels
        let evidence: Labels
    }

    private struct Labels: Codable {
        private let groups: [TagGroup: [String]]

        init(_ metadata: PhotoMetadata) {
            groups = Dictionary(uniqueKeysWithValues: TagGroup.allCases.map { ($0, metadata[keyPath: $0.field]) })
        }

        init(_ analysis: ImageAnalysis) {
            let modelTags: [TagGroup: [String]] = [
                .subjects: analysis.subjects,
                .topics: (analysis.topics ?? []) + analysis.subjects,
                .moods: (analysis.moods ?? []) + (analysis.styles ?? []),
                .styles: analysis.styles ?? [],
            ]
            groups = modelTags.mapValues { $0.map(TagRules.key).filter { !$0.isEmpty } }
        }

        func values(for group: TagGroup) -> [String] { groups[group] ?? [] }
    }
}

final class FileAccessLock {
    private let descriptor: Int32

    init(url: URL) throws {
        let file = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(file, LOCK_EX) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(file)
            throw POSIXError(code)
        }
        descriptor = file
    }

    deinit { close(descriptor) }
}
