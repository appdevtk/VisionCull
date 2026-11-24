import Foundation
import VisionCullCore

extension Command {
    static func searchCommands(_ args: [String]) throws {
        let options = try Options(Array(args.dropFirst()), values: ["--cache", "--query", "--topics", "--moods", "--styles", "--stars"])
        let library = library(options)
        switch args.first {
        case "save":
            try options.expect(1)
            let query = ReviewFilterQuery(
                text: options.value("--query") ?? "", topics: terms(options, "--topics"),
                moods: terms(options, "--moods"), styles: terms(options, "--styles"),
                minimumStars: try rating(options, "--stars") ?? 0
            )
            try library.save(SavedSearch(name: options.positionals[0], query: query))
        case "list":
            try options.expect(0)
            for search in try library.read().searches { print(search.name) }
        case "run":
            try options.expect(2)
            let prefs = try library.read()
            let query = try preset(options.positionals[0], in: prefs).query
            let review = try Review.read(file(options.positionals[1]))
            for photo in query.matching(review.photos, aliases: prefs.aliases) { print(photo.relativePath) }
        case "remove":
            try options.expect(1)
            let search = try preset(options.positionals[0], in: library.read())
            try library.removeSearch(search.id)
        default: throw WorkflowError.message("Choose search save, list, run, or remove.")
        }
    }

    static func tagCommands(_ args: [String]) async throws {
        let options = try Options(Array(args.dropFirst()), values: ["--cache", "--server"])
        let library = library(options)
        switch args.first {
        case "alias":
            try options.expect(3)
            guard let group = TagGroup.allCases.first(where: {
                $0.rawValue.lowercased() == options.positionals[0].lowercased()
            }) else { throw WorkflowError.message("Choose Motifs, Topics, Moods, or Styles.") }
            try library.save(TagAlias(group: group, alias: options.positionals[1], preferred: options.positionals[2]))
        case "list":
            try options.expect(0)
            for rule in try library.read().aliases { print("\(rule.id) \(rule.group.rawValue): \(rule.alias) → \(rule.preferred)") }
        case "remove":
            try options.expect(1)
            try library.removeAlias(uuid(options.positionals[0], option: "Alias"))
        case "duplicates":
            let matches: [TagSimilarity]
            if options.has("--server") {
                try options.expect(0)
                matches = try await remoteClient(options).similarTags()
            } else {
                try options.expect(1)
                let photos = try Review.read(file(options.positionals[0])).photos
                matches = try TagInventory.similar(in: photos, aliases: library.read().aliases)
            }
            for pair in matches { print("\(pair.group.rawValue): \(pair.first) · \(pair.second)") }
        default: throw WorkflowError.message("Choose tags alias, list, remove, or duplicates.")
        }
    }

    static func batchEdit(_ args: [String]) throws {
        let options = try Options(
            args, values: ["--cache", "--preset", "--topics", "--moods", "--styles", "--rating", "--tag-mode"], flags: ["--all"]
        )
        guard let path = options.positionals.first else { throw WorkflowError.message("Specify a review file.") }
        let url = file(path)
        let revision = try FileRevision.read(url)
        let review = try Review.read(url)
        let photos = try selectedPhotos(options, review: review)
        guard let operation = BatchMetadataEdit.Operation(rawValue: options.value("--tag-mode") ?? "add") else {
            throw WorkflowError.message("--tag-mode must be add, remove, or replace.")
        }
        let edit = BatchMetadataEdit(
            topics: terms(options, "--topics"), moods: terms(options, "--moods"), styles: terms(options, "--styles"),
            rating: try rating(options, "--rating"), operation: operation
        )
        let updated = try edit.applying(to: review, ids: Set(photos.map(\.id)), aliases: preferences(options).aliases)
        try write(updated, to: url, revision: revision)
        print("Reviewed edits for \(photos.count) selected photos.")
    }

    static func find(_ args: [String]) throws {
        let options = try Options(args, values: ["--text", "--image", "--limit", "--cache"])
        try options.expect(1)
        guard options.has("--text") != options.has("--image"),
              let limit = Int(options.value("--limit") ?? "50"), limit > 0 else {
            throw WorkflowError.message("Choose --text or --image and a positive --limit.")
        }
        let search = ContentSearch(root: cache(options))
        let photos = try Review.read(file(options.positionals[0])).photos
        let matches: ContentMatches
        if let text = options.value("--text") { matches = try search.text(text, in: photos, limit: limit) }
        else { matches = try search.image(file(options.required("--image")), in: photos, limit: limit) }
        for hit in matches.hits { print("\(String(format: "%.3f", hit.score)) \(hit.photo.relativePath)") }
        for issue in matches.issues { print("! \(issue.path): \(issue.message)") }
    }

    static func series(_ args: [String]) throws {
        let options = try Options(args, values: ["--favorite"])
        guard options.positionals.count >= 2 else { throw WorkflowError.message("Specify a review and at least one photo.") }
        let url = file(options.positionals[0])
        let revision = try FileRevision.read(url)
        var review = try Review.read(url)
        let specified = try options.positionals.dropFirst().map { review.photos[try index($0, in: review)].id }
        let group = specified.count == 1 ? review.duplicateGroups().first { $0.contains(specified[0]) } ?? [] : specified
        guard Set(group).count >= 2 else { throw WorkflowError.message("Choose two photos or scan with --duplicates first.") }
        if let choice = options.value("--favorite") {
            let id = review.photos[try index(choice, in: review)].id
            guard group.contains(id) else { throw WorkflowError.message("The favorite must be in the comparison.") }
            review.setFavorite(id, in: group)
            try write(review, to: url, revision: revision)
        }
        let favorite = review.suggestedFavorite(in: group)
        for photo in review.photos where group.contains(photo.id) {
            print("\(photo.id == favorite ? "★ " : "")\(photo.relativePath)")
            if let score = photo.analysis.aestheticScore { print("  Vision score: \(score)") }
            if let detail = photo.analysis.appearance?.edgeDetail { print("  Edge detail: \(detail)") }
            if let look = photo.analysis.appearance { print("  Brightness: \(look.brightness) Shadows: \(look.shadowFraction) Highlights: \(look.highlightFraction)") }
        }
    }

    static func immichSource(_ args: [String]) async throws {
        let scanning = args.first == "scan"
        let values: Set<String> = scanning ? ["--server", "--cache", "--album", "--review"] : ["--server", "--cache"]
        let flags: Set<String> = scanning ? ["--duplicates", "--metadata-only"] : []
        let options = try Options(Array(args.dropFirst()), values: values, flags: flags)
        try options.expect(0)
        let client = try remoteClient(options)
        if !scanning {
            for album in try await client.albums() {
                print("\(album.id.uuidString) \(album.albumName) (\(album.assetCount) assets)")
            }
            return
        }
        #if !os(macOS)
        guard options.has("--metadata-only") else {
            throw WorkflowError.message("Apple Vision requires macOS. Use --metadata-only to inspect Immich metadata on Linux.")
        }
        #endif
        let destination = file(try options.required("--review"))
        guard destination.pathExtension.lowercased() == "json", !FileManager.default.fileExists(atPath: destination.path) else {
            throw WorkflowError.message("Choose a new .json file for the review.")
        }
        let album = try uuid(options.required("--album"), option: "--album")
        let analyzer: any PhotoAnalyzer = options.has("--metadata-only")
            ? MetadataOnly() : LocalVisionAnalyzer(includeDuplicates: options.has("--duplicates"))
        let review = try await client.scanAlbum(album, scanner: PhotoScanner(cacheRoot: cache(options), analyzer: analyzer))
        try review.write(destination)
        print("\(review.photos.count) Immich previews, \(review.analyzed) analyzed, \(review.reused) cached, \(review.issues.count) issues")
        for issue in review.issues { print("! \(issue.path): \(issue.message)") }
    }

    static func immichBatch(_ args: [String]) async throws {
        let options = try Options(args, values: ["--server", "--cache", "--preset", "--map"], flags: ["--all", "--apply"])
        guard let path = options.positionals.first else { throw WorkflowError.message("Specify a review file.") }
        let review = try Review.read(file(path))
        let selected = try selectedPhotos(options, review: review)
        let photos = selected.filter(\.approved)
        for photo in selected where !photo.approved { print("! \(photo.relativePath): Pending local approval.") }
        guard !photos.isEmpty else { throw WorkflowError.message("Select at least one approved photo.") }
        let overrides = try options.value("--map").map {
            try JSONDecoder().decode([String: BatchOverride].self, from: Data(contentsOf: file($0)))
        } ?? [:]
        var intents = [String: ImmichBatchIntent]()
        for (selector, rule) in overrides {
            let photo = review.photos[try index(selector, in: review)]
            guard photos.contains(where: { $0.id == photo.id }), intents[photo.id] == nil else {
                throw WorkflowError.message("Map entry \(selector) must uniquely identify a selected, approved photo.")
            }
            switch (rule.assetID, rule.uploadAlbumID) {
            case (let id?, nil): intents[photo.id] = .update(id)
            case (nil, let album?): intents[photo.id] = .upload(album: album)
            default: throw WorkflowError.message("Map entry \(selector) must contain only assetID or uploadAlbumID.")
            }
        }
        let requests = photos.map { ImmichBatchRequest(photo: $0, intent: intents[$0.id] ?? .matchExisting) }
        let client = try remoteClient(options)
        let preview = try await client.previewBatch(requests)
        for row in preview {
            if let problem = row.problem { print("! \(row.path): \(problem)"); continue }
            let target = row.assetID.map { "Update \($0)" } ?? row.albumID.map { "Upload to \($0)" } ?? ""
            print("\(row.path): \(target)")
            if !row.reusedTags.isEmpty { print("  Reuse: \(row.reusedTags.joined(separator: ", "))") }
            if !row.newTags.isEmpty { print("  Create: \(row.newTags.joined(separator: ", "))") }
            if !row.metadataChanges.isEmpty { print("  \(row.metadataChanges.joined(separator: " · "))") }
        }
        if options.has("--apply") {
            guard selected.count == photos.count, preview.allSatisfy(\.isReady) else {
                throw WorkflowError.message("Resolve all preview issues or narrow the selection before using --apply.")
            }
            let results = try await client.applyBatch(preview)
            for result in results {
                if let problem = result.problem { print("! \(result.path): \(problem)") }
                else if let id = result.assetID { print("Sent \(result.path) → \(id)") }
            }
            if results.contains(where: { $0.problem != nil }) {
                throw WorkflowError.message("Some Immich updates did not complete.")
            }
        }
    }

    private struct BatchOverride: Decodable {
        let assetID: UUID?
        let uploadAlbumID: UUID?
    }

    private static func selectedPhotos(_ options: Options, review: Review) throws -> [PhotoEntry] {
        let selectors = options.positionals.dropFirst()
        let modes = (options.has("--all") ? 1 : 0) + (options.has("--preset") ? 1 : 0) + (selectors.isEmpty ? 0 : 1)
        guard modes == 1 else { throw WorkflowError.message("Choose --all, a saved --preset, or specific photo paths.") }
        if options.has("--all") { return review.photos }
        if let name = options.value("--preset") {
            let prefs = try preferences(options)
            return try preset(name, in: prefs).query.matching(review.photos, aliases: prefs.aliases)
        }
        let indices = try Set(selectors.map { try index($0, in: review) })
        return review.photos.indices.filter(indices.contains).map { review.photos[$0] }
    }

    private static func preset(_ name: String, in preferences: ReviewPreferences) throws -> SavedSearch {
        guard let search = preferences.searches.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw WorkflowError.message("No saved search named \(name).")
        }
        return search
    }

    static func remoteClient(_ options: Options) throws -> ImmichClient {
        guard let url = URL(string: try options.required("--server")) else { throw WorkflowError.message("Invalid Immich URL.") }
        return try ImmichClient(server: url, apiKey: ProcessInfo.processInfo.environment["IMMICH_API_KEY"] ?? "",
                                aliases: preferences(options).aliases)
    }

    static func preferences(_ options: Options) throws -> ReviewPreferences { try library(options).read() }

    private static func cache(_ options: Options) -> URL { options.value("--cache").map(file) ?? PhotoScanner.defaultCache }

    private static func library(_ options: Options) -> ReviewLibrary { ReviewLibrary(root: cache(options)) }

    private static func terms(_ options: Options, _ name: String) -> [String] {
        (options.value(name) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func rating(_ options: Options, _ name: String) throws -> Int? {
        guard let input = options.value(name) else { return nil }
        guard let number = Int(input), (0...5).contains(number) else { throw WorkflowError.message("\(name) must be 0 through 5.") }
        return number
    }

    private static func write(_ review: Review, to url: URL, revision: FileRevision) throws {
        guard try FileRevision.read(url) == revision else { throw WorkflowError.message("The review changed. Open it again and retry.") }
        try review.write(url, replacingReview: true)
    }
}
