import Foundation

public struct ReviewFilterQuery: Codable, Equatable, Sendable {
    public var text: String
    public var topics: [String]
    public var moods: [String]
    public var styles: [String]
    public var minimumStars: Int

    public init(text: String = "", topics: [String] = [], moods: [String] = [], styles: [String] = [], minimumStars: Int = 0) {
        self.text = text
        self.topics = topics
        self.moods = moods
        self.styles = styles
        self.minimumStars = minimumStars
    }

    public func matching(_ photos: [PhotoEntry], aliases: [TagAlias] = []) -> [PhotoEntry] {
        let rules = TagRules(custom: aliases)
        return photos.filter { photo in
            (photo.metadata.rating ?? 0) >= minimumStars && photo.matchesSearch(text, rules: rules)
                && contains(topics, in: photo.metadata.topics, group: .topics, rules: rules)
                && contains(moods, in: photo.metadata.moods, group: .moods, rules: rules)
                && contains(styles, in: photo.metadata.styles, group: .styles, rules: rules)
        }
    }

    private func contains(_ requested: [String], in present: [String], group: TagGroup, rules: TagRules) -> Bool {
        requested.allSatisfy { name in present.contains { rules.equivalent(name, $0, in: group) } }
    }
}

public struct SavedSearch: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var query: ReviewFilterQuery

    public init(id: UUID = UUID(), name: String, query: ReviewFilterQuery) {
        self.id = id
        self.name = name
        self.query = query
    }
}

public struct TagAlias: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var group: TagGroup
    public var alias: String
    public var preferred: String

    public init(id: UUID = UUID(), group: TagGroup, alias: String, preferred: String) {
        self.id = id
        self.group = group
        self.alias = alias
        self.preferred = preferred
    }
}

public struct ReviewPreferences: Codable, Sendable {
    public var searches: [SavedSearch] = []
    public var aliases: [TagAlias] = []

    public init() {}
}

public struct ReviewLibrary: Sendable {
    private let root: URL

    public init(root: URL = PhotoScanner.defaultCache) { self.root = root }

    public func read() throws -> ReviewPreferences {
        do { return try JSONDecoder().decode(ReviewPreferences.self, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return ReviewPreferences() }
    }

    @discardableResult
    public func save(_ search: SavedSearch) throws -> ReviewPreferences {
        try change { preferences in
            var entry = search
            entry.name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.name.isEmpty, (0...5).contains(entry.query.minimumStars) else {
                throw WorkflowError.message("Enter a name and a minimum rating between 0 and 5.")
            }
            let sameID = preferences.searches.firstIndex { $0.id == entry.id }
            let sameName = preferences.searches.firstIndex { $0.name.caseInsensitiveCompare(entry.name) == .orderedSame }
            if let sameID, let sameName, sameID != sameName {
                throw WorkflowError.message("A different saved search already uses that name.")
            }
            if let existing = sameID ?? sameName {
                let id = preferences.searches[existing].id
                preferences.searches[existing] = SavedSearch(id: id, name: entry.name, query: entry.query)
            } else {
                preferences.searches.append(entry)
            }
        }
    }

    @discardableResult
    public func removeSearch(_ id: UUID) throws -> ReviewPreferences {
        try change { $0.searches.removeAll { $0.id == id } }
    }

    @discardableResult
    public func save(_ rule: TagAlias) throws -> ReviewPreferences {
        try change { preferences in
            let alias = rule.alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let preferred = rule.preferred.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !TagRules.key(alias).isEmpty, !TagRules.key(preferred).isEmpty,
                  !alias.contains("/"), !preferred.contains("/") else {
                throw WorkflowError.message("Enter two tag names without slashes.")
            }
            let index = preferences.aliases.firstIndex {
                $0.id == rule.id || ($0.group == rule.group && TagRules.baseKey($0.alias, in: rule.group) == TagRules.baseKey(alias, in: rule.group))
            }
            if let index { preferences.aliases.remove(at: index) }
            preferences.aliases.append(TagAlias(id: rule.id, group: rule.group, alias: alias, preferred: preferred))
            try TagRules.validate(custom: preferences.aliases)
        }
    }

    @discardableResult
    public func removeAlias(_ id: UUID) throws -> ReviewPreferences {
        try change { $0.aliases.removeAll { $0.id == id } }
    }

    private var file: URL { root.appendingPathComponent("review-preferences.json") }

    private func change(_ edit: (inout ReviewPreferences) throws -> Void) throws -> ReviewPreferences {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = try FileAccessLock(url: root.appendingPathComponent("review-preferences.lock"))
        defer { withExtendedLifetime(lock) {} }
        var preferences = try read()
        try edit(&preferences)
        try JSONEncoder().encode(preferences).write(to: file, options: .atomic)
        return preferences
    }
}

public struct BatchMetadataEdit: Sendable {
    public var topics: [String]
    public var moods: [String]
    public var styles: [String]
    public var rating: Int?

    public init(topics: [String] = [], moods: [String] = [], styles: [String] = [], rating: Int? = nil) {
        self.topics = topics
        self.moods = moods
        self.styles = styles
        self.rating = rating
    }

    public func applying(to review: Review, ids: Set<String>) throws -> Review {
        var updated = review
        for i in updated.photos.indices where ids.contains(updated.photos[i].id) {
            var metadata = updated.photos[i].metadata
            metadata.topics += topics
            metadata.moods += moods
            metadata.styles += styles
            if let rating { metadata.rating = rating == 0 ? nil : rating }
            metadata = try metadata.validated()
            if metadata != updated.photos[i].metadata {
                updated.photos[i].metadata = metadata
                updated.photos[i].approved = false
            }
        }
        return updated
    }
}

public struct TagSimilarity: Hashable, Identifiable, Sendable {
    public let group: TagGroup
    public let first: String
    public let second: String
    public var id: String { "\(group.rawValue):\(first.utf8.count):\(first)\(second)" }
}

public enum TagInventory {
    public static func similar(in photos: [PhotoEntry], aliases: [TagAlias] = []) -> [TagSimilarity] {
        let grouped = Dictionary(uniqueKeysWithValues: TagGroup.allCases.map { group in
            let names = photos.flatMap { $0.metadata[keyPath: group.field] + $0.existing[keyPath: group.field] }
            return (group, names)
        })
        return similar(in: grouped, rules: TagRules(custom: aliases))
    }

    static func similar(in grouped: [TagGroup: [String]], rules: TagRules) -> [TagSimilarity] {
        var pairs = Set<TagSimilarity>()
        for group in TagGroup.allCases {
            let entries = Set(grouped[group] ?? []).map { value in
                (path: value, leaf: value.split(separator: "/").last.map(String.init) ?? value)
            }
            func add(_ first: String, _ second: String) {
                guard first != second else { return }
                pairs.insert(TagSimilarity(group: group, first: min(first, second), second: max(first, second)))
            }
            let families = Dictionary(grouping: entries) { rules.identity($0.leaf, in: group) }
            for family in families.values {
                for (index, first) in family.enumerated() {
                    for second in family.dropFirst(index + 1) { add(first.path, second.path) }
                }
            }
            let spellings = Dictionary(grouping: entries) { TagRules.key($0.leaf) }
            for (key, names) in spellings {
                for variant in typoVariants(of: key) {
                    guard let peers = spellings[variant] else { continue }
                    for name in names {
                        for peer in peers { add(name.path, peer.path) }
                    }
                }
            }
        }
        return pairs.sorted { ($0.group.rawValue, $0.first, $0.second) < ($1.group.rawValue, $1.first, $1.second) }
    }

    // A near match is one missing/extra character or an adjacent transposition, as in TagRules.
    private static func typoVariants(of key: String) -> Set<String> {
        let characters = Array(key)
        guard characters.count >= 6 else { return [] }
        var variants = Set<String>()
        for index in characters.indices where characters[index] != " " {
            if characters.count > 6 {
                var shorter = characters
                shorter.remove(at: index)
                variants.insert(String(shorter))
            }
            if index + 1 < characters.count, characters[index + 1] != " ", characters[index] != characters[index + 1] {
                var swapped = characters
                swapped.swapAt(index, index + 1)
                variants.insert(String(swapped))
            }
        }
        return variants
    }
}
