import Foundation
import VisionCullCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@main
struct Command {
    static let help = """
    VisionCull — local photo review for macOS

      visioncull scan FOLDER --review REVIEW.json [--cache DIR] [--duplicates] [--metadata-only]
      visioncull photos --review REVIEW.json [--cache DIR] [--limit N] [--offset N] [--icloud] [--duplicates]
      visioncull preview REVIEW.json [--search QUERY]
      visioncull edit REVIEW.json PHOTO [--subjects A,B] [--category NAME] [--description TEXT]
                     [--topics A,B] [--moods A,B] [--styles A,B] [--rating 0…5]
                     [--date ISO-8601] [--latitude DECIMAL --longitude DECIMAL | --clear-gps]
      visioncull approve REVIEW.json (--all | PHOTO...)
      visioncull export REVIEW.json (--alongside | --output DIR)
      visioncull immich update REVIEW.json PHOTO --server URL --asset-id UUID [--album UUID]
      visioncull immich upload REVIEW.json PHOTO --server URL --album UUID

    PHOTO is an exact relative path or ID from preview. Edits clear prior approval.
    Use a rating of 0 to clear stars in the review.
    Immich reads IMMICH_API_KEY from the environment. Upload sends only the named approved image.
    """

    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first, command != "--help", command != "help" else {
            print(help)
            return
        }
        let args = Array(arguments.dropFirst())
        switch command {
        case "scan", "photos":
            let isFolder = command == "scan"
            let allowed: Set<String> = isFolder ? ["--review", "--cache"] : ["--review", "--cache", "--limit", "--offset"]
            let flags: Set<String> = isFolder ? ["--duplicates", "--metadata-only"] : ["--duplicates", "--icloud"]
            let options = try Options(args, values: allowed, flags: flags)
            try options.expect(isFolder ? 1 : 0)
            let path = try options.required("--review")
            let analyzer: any PhotoAnalyzer = options.has("--metadata-only")
                ? MetadataOnly() : LocalVisionAnalyzer(includeDuplicates: options.has("--duplicates"))
            #if !os(macOS)
            if isFolder && !options.has("--metadata-only") {
                throw WorkflowError.message("Apple Vision requires macOS. Use --metadata-only to exercise the portable workflow.")
            }
            #endif
            let scanner = PhotoScanner(cacheRoot: options.value("--cache").map(file) ?? PhotoScanner.defaultCache, analyzer: analyzer)
            let review: Review
            if isFolder {
                review = try scanner.scan(folder: file(options.positionals[0]))
            } else {
                let limit = options.value("--limit") ?? "50"
                guard let limit = Int(limit), limit > 0 else { throw WorkflowError.message("--limit must be positive.") }
                guard let offset = Int(options.value("--offset") ?? "0"), offset >= 0 else {
                    throw WorkflowError.message("--offset must be nonnegative.")
                }
                review = try await ApplePhotos.scan(scanner: scanner, limit: limit, offset: offset, allowICloud: options.has("--icloud"))
            }
            try review.write(file(path))
            print("\(review.photos.count) photos, \(review.analyzed) analyzed, \(review.reused) cached, \(review.issues.count) issues")
            for issue in review.issues { print("! \(issue.path): \(issue.message)") }
        case "preview":
            let options = try Options(args, values: ["--search"])
            try options.expect(1)
            let review = try Review.read(file(options.positionals[0]))
            let query = options.value("--search") ?? ""
            let matches = review.photos.filter { $0.matchesSearch(query) }
            for entry in matches {
                let value = entry.metadata
                let coords = value.latitude.flatMap { lat in value.longitude.map { "\(lat), \($0)" } } ?? ""
                print("[\(entry.approved ? "approved" : "pending")] \(entry.relativePath)")
                print("  \(value.category) | \(value.subjects.joined(separator: ", ")) | \(value.description)")
                if !value.capturedAt.isEmpty || !coords.isEmpty { print("  \(value.capturedAt) \(coords)") }
                if !value.topics.isEmpty { print("  Topics: \(value.topics.joined(separator: ", "))") }
                if !value.moods.isEmpty { print("  Moods: \(value.moods.joined(separator: ", "))") }
                if !value.styles.isEmpty { print("  Styles: \(value.styles.joined(separator: ", "))") }
                if let rating = value.rating { print("  Stars: \(rating)/5") }
                printAppearance(entry.analysis)
            }
            let names = Dictionary(matches.map { ($0.id, $0.relativePath) }, uniquingKeysWith: { first, _ in first })
            if matches.isEmpty && !query.isEmpty { print("No photos matched.") }
            for group in review.duplicateGroups() {
                let paths = group.compactMap { names[$0] }
                if paths.count > 1 { print("Similar: \(paths.joined(separator: " | "))") }
            }
            for issue in review.issues { print("! \(issue.path): \(issue.message)") }
        case "edit":
            try edit(Options(args, values: [
                "--subjects", "--category", "--description", "--date", "--latitude", "--longitude",
                "--topics", "--moods", "--styles", "--rating",
            ], flags: ["--clear-gps"]))
        case "approve":
            let options = try Options(args, flags: ["--all"])
            guard let path = options.positionals.first, options.has("--all") == (options.positionals.count == 1) else {
                throw WorkflowError.message("Specify a review and either --all or exact photo paths.")
            }
            let url = file(path)
            var review = try Review.read(url)
            let indices = try options.has("--all") ? Array(review.photos.indices)
                : options.positionals.dropFirst().map { try index($0, in: review) }
            guard !indices.isEmpty else { throw WorkflowError.message("There are no photos to approve.") }
            for i in Set(indices) {
                review.photos[i].metadata = try review.photos[i].metadata.validated()
                review.photos[i].approved = true
            }
            try review.write(url, replacingReview: true)
            print("Approved \(Set(indices).count) photos.")
        case "export":
            let options = try Options(args, values: ["--output"], flags: ["--alongside"])
            try options.expect(1)
            guard options.has("--alongside") != options.has("--output") else {
                throw WorkflowError.message("Choose either --alongside or --output DIR.")
            }
            let target: SidecarTarget = try options.has("--alongside") ? .alongside : .folder(file(options.required("--output")))
            let result = try XMP.export(Review.read(file(options.positionals[0])), to: target)
            for url in result { print(url.path) }
        case "immich":
            try await immich(args)
        default:
            throw WorkflowError.message("Unknown command '\(command)'. See --help.")
        }
    }

    private static func printAppearance(_ analysis: ImageAnalysis) {
        if let score = analysis.aestheticScore { print("  Vision score: \(score)") }
        if analysis.isUtility == true { print("  Vision considers this a utility image.") }
        guard let look = analysis.appearance else { return }
        let percent = FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(0))
        print("  Brightness \(look.brightness.formatted(percent)) | Contrast \(look.contrast.formatted(percent)) | Saturation \(look.saturation.formatted(percent))")
        print("  Deep shadows \(look.shadowFraction.formatted(percent)) | Near-white highlights \(look.highlightFraction.formatted(percent)) | Palette \(look.palette.joined(separator: " "))")
    }

    private static func edit(_ options: Options) throws {
        try options.expect(2)
        let url = file(options.positionals[0])
        var review = try Review.read(url)
        let i = try index(options.positionals[1], in: review)
        var data = review.photos[i].metadata
        if let value = options.value("--subjects") { data.subjects = value.components(separatedBy: ",") }
        if let value = options.value("--topics") { data.topics = value.components(separatedBy: ",") }
        if let value = options.value("--moods") { data.moods = value.components(separatedBy: ",") }
        if let value = options.value("--styles") { data.styles = value.components(separatedBy: ",") }
        if let value = options.value("--rating") {
            guard let rating = Int(value), (0...5).contains(rating) else {
                throw WorkflowError.message("--rating must be 0 through 5.")
            }
            data.rating = rating == 0 ? nil : rating
        }
        if let value = options.value("--category") { data.category = value }
        if let value = options.value("--description") { data.description = value }
        if let value = options.value("--date") { data.capturedAt = value }
        let gps = options.has("--latitude") || options.has("--longitude")
        if options.has("--clear-gps") {
            guard !gps else { throw WorkflowError.message("Use --clear-gps or enter both coordinates.") }
            data.latitude = nil
            data.longitude = nil
        } else if gps {
            guard let latitude = options.value("--latitude").flatMap(Double.init),
                  let longitude = options.value("--longitude").flatMap(Double.init) else {
                throw WorkflowError.message("Enter both GPS coordinates in decimal degrees.")
            }
            data.latitude = latitude
            data.longitude = longitude
        }
        review.photos[i].metadata = try data.validated()
        review.photos[i].approved = false
        try review.write(url, replacingReview: true)
    }

    private static func immich(_ args: [String]) async throws {
        guard let action = args.first, ["update", "upload"].contains(action) else {
            throw WorkflowError.message("Choose the Immich action update or upload.")
        }
        let options = try Options(
            Array(args.dropFirst()),
            values: action == "update" ? ["--server", "--asset-id", "--album"] : ["--server", "--album"]
        )
        try options.expect(2)
        let review = try Review.read(file(options.positionals[0]))
        let photo = review.photos[try index(options.positionals[1], in: review)]
        guard let url = URL(string: try options.required("--server")) else { throw WorkflowError.message("Invalid Immich URL.") }
        let client = try ImmichClient(server: url, apiKey: ProcessInfo.processInfo.environment["IMMICH_API_KEY"] ?? "")
        let album = try options.value("--album").map { try uuid($0, option: "--album") }
        if action == "update" {
            let asset = try uuid(options.required("--asset-id"), option: "--asset-id")
            try await client.update(photo, assetID: asset, addToAlbum: album)
            print("Updated asset \(asset.uuidString).")
        } else {
            guard let album else { throw WorkflowError.message("Upload requires an explicit --album UUID.") }
            let asset = try await client.upload(photo, album: album)
            print("Uploaded asset \(asset.uuidString) to album \(album.uuidString).")
        }
    }

    private static func file(_ path: String) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
    }

    private static func uuid(_ string: String, option: String) throws -> UUID {
        guard let value = UUID(uuidString: string) else { throw WorkflowError.message("\(option) requires a UUID.") }
        return value
    }

    private static func index(_ selector: String, in review: Review) throws -> Int {
        let matches = review.photos.indices.filter {
            review.photos[$0].relativePath == selector || review.photos[$0].id == selector
        }
        guard matches.count == 1, let i = matches.first else {
            throw WorkflowError.message("Photo selector '\(selector)' is missing or ambiguous; use an exact path or ID.")
        }
        return i
    }
}

private struct MetadataOnly: PhotoAnalyzer {
    let cacheVersion = "metadata-only-1"
    func analyze(_ file: URL) throws -> ImageAnalysis { ImageAnalysis() }
}

private struct Options {
    var positionals: [String] = []
    private var arguments: [String: String] = [:]

    init(_ input: [String], values: Set<String> = [], flags: Set<String> = []) throws {
        var i = 0
        while i < input.count {
            let argument = input[i]
            if argument == "--" {
                positionals += input.dropFirst(i + 1)
                return
            }
            if argument.hasPrefix("--") {
                guard arguments[argument] == nil else { throw WorkflowError.message("Repeated option \(argument).") }
                if flags.contains(argument) {
                    arguments[argument] = ""
                } else if values.contains(argument), i + 1 < input.count, !input[i + 1].hasPrefix("--") {
                    i += 1
                    arguments[argument] = input[i]
                } else {
                    throw WorkflowError.message("Unknown option or missing value: \(argument).")
                }
            } else {
                positionals.append(argument)
            }
            i += 1
        }
    }

    func has(_ name: String) -> Bool { arguments[name] != nil }
    func value(_ name: String) -> String? { arguments[name] }

    func required(_ name: String) throws -> String {
        guard let value = arguments[name], !value.isEmpty else { throw WorkflowError.message("Specify \(name).") }
        return value
    }

    func expect(_ count: Int) throws {
        guard positionals.count == count else { throw WorkflowError.message("Wrong number of arguments. See --help.") }
    }
}
