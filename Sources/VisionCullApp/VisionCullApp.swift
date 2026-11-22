import Foundation
import VisionCullCore

#if os(macOS)
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct VisionCullApp: App {
    var body: some Scene {
        WindowGroup("VisionCull") { WorkspaceView() }
            .defaultSize(width: 1240, height: 790)
    }
}

private enum ReviewFilter: String, CaseIterable {
    case all = "All photos"
    case pending = "Pending"
    case approved = "Approved"
    case similar = "Similar photos"
}

@MainActor
private final class Workspace: ObservableObject {
    @Published var review: Review?
    @Published var selection: String?
    @Published var marked = Set<String>()
    @Published var matches: [String: [String]] = [:]
    @Published var activity: String?
    @Published var status = ""
    @Published var alert: String?
    @Published var sourceName = ""
    @Published var duplicates = false
    @Published var allowICloud = false
    @Published var photosLimit = 50

    func openFolder() {
        guard let url = chooseFolder("Scan Folder") else { return }
        let analyzer = LocalVisionAnalyzer(includeDuplicates: duplicates)
        load("Scanning \(url.lastPathComponent)…", source: url.lastPathComponent) {
            try PhotoScanner(analyzer: analyzer).scan(folder: url)
        }
    }

    func openPhotos() {
        let scanner = PhotoScanner(analyzer: LocalVisionAnalyzer(includeDuplicates: duplicates))
        let limit = photosLimit
        let download = allowICloud
        load("Reading Apple Photos…", source: "Apple Photos") {
            try await ApplePhotos.scan(scanner: scanner, limit: limit, allowICloud: download)
        }
    }

    func openReview() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            load("Opening review…", source: url.deletingPathExtension().lastPathComponent) { try Review.read(url) }
        }
    }

    func saveReview() {
        guard let review else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "VisionCull Review.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try review.write(url, replacingReview: FileManager.default.fileExists(atPath: url.path))
                status = "Saved review."
            } catch { alert = error.localizedDescription }
        }
    }

    func apply(_ metadata: PhotoMetadata, to id: String) throws -> PhotoEntry {
        guard var review, let index = review.photos.firstIndex(where: { $0.id == id }) else {
            throw WorkflowError.message("This photo is no longer in the review.")
        }
        let verified = try metadata.validated()
        if review.photos[index].metadata != verified {
            review.photos[index].metadata = verified
            review.photos[index].approved = false
        }
        self.review = review
        status = "Saved edits for \(review.photos[index].file.lastPathComponent)."
        return review.photos[index]
    }

    func mark(_ id: String, enabled: Bool) {
        if enabled { marked.insert(id) } else { marked.remove(id) }
    }

    func approveMarked() {
        guard var review else { return }
        do {
            for index in review.photos.indices where marked.contains(review.photos[index].id) {
                review.photos[index].metadata = try review.photos[index].metadata.validated()
                review.photos[index].approved = true
            }
            self.review = review
            status = "Approved \(marked.count) photos."
            marked.removeAll()
        } catch { alert = error.localizedDescription }
    }

    func revoke(_ id: String) {
        if let index = review?.photos.firstIndex(where: { $0.id == id }) {
            review?.photos[index].approved = false
        }
    }

    func export(alongside: Bool) {
        guard let review else { return }
        let target: SidecarTarget
        if alongside {
            target = .alongside
        } else {
            guard let url = chooseFolder("Choose XMP Export Folder", create: true) else { return }
            target = .folder(url)
        }
        activity = "Exporting XMP…"
        Task {
            defer { activity = nil }
            do {
                let urls = try await Task.detached(priority: .userInitiated) { try XMP.export(review, to: target) }.value
                status = "Exported \(urls.count) XMP sidecars."
            } catch { alert = error.localizedDescription }
        }
    }

    private func chooseFolder(_ prompt: String, create: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = create
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func load(_ label: String, source: String, operation: @escaping @Sendable () async throws -> Review) {
        activity = label
        Task {
            defer { activity = nil }
            do {
                let (result, matches) = try await Task.detached(priority: .userInitiated) {
                    let review = try await operation()
                    let groups = review.duplicateGroups()
                    let links = Dictionary(uniqueKeysWithValues: groups.flatMap { group in
                        group.map { ($0, group) }
                    })
                    return (review, links)
                }.value
                review = result
                self.matches = matches
                sourceName = source
                marked.removeAll()
                selection = result.photos.first?.id
                status = "\(result.photos.count) photos · \(result.analyzed) analyzed · \(result.reused) cached"
            } catch { alert = error.localizedDescription }
        }
    }
}

@MainActor
private struct WorkspaceView: View {
    @StateObject private var workspace = Workspace()
    @State private var filter: ReviewFilter = .all
    @State private var query = ""
    @State private var photosOptions = false
    @State private var showIssues = false
    @State private var confirmApproval = false
    @State private var confirmAlongside = false

    private var photos: [PhotoEntry] { workspace.review?.photos ?? [] }
    private var visible: [PhotoEntry] {
        photos.filter { photo in
            let matches: Bool
            switch filter {
            case .all: matches = true
            case .pending: matches = !photo.approved
            case .approved: matches = photo.approved
            case .similar: matches = workspace.matches[photo.id] != nil
            }
            return matches && (query.isEmpty || photo.relativePath.localizedCaseInsensitiveContains(query)
                || photo.metadata.subjects.joined(separator: " ").localizedCaseInsensitiveContains(query)
                || photo.metadata.category.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("Show", selection: $filter) {
                    ForEach(ReviewFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .padding(12)
                List(visible, selection: $workspace.selection) { entry in
                    HStack(spacing: 10) {
                        Toggle("Mark \(entry.file.lastPathComponent) for approval", isOn: Binding(
                            get: { workspace.marked.contains(entry.id) },
                            set: { workspace.mark(entry.id, enabled: $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        Thumbnail(url: entry.file, pixels: 120)
                            .frame(width: 52, height: 42)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.file.lastPathComponent).lineLimit(1)
                            Text(entry.metadata.category.isEmpty ? entry.relativePath : entry.metadata.category)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if entry.approved {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                .accessibilityLabel("Approved")
                        }
                    }
                    .tag(entry.id)
                }
                HStack {
                    Button("Mark Visible") { workspace.marked.formUnion(visible.map(\.id)) }
                        .disabled(visible.isEmpty)
                    Spacer()
                    Button("Clear Marks") { workspace.marked.removeAll() }
                        .disabled(workspace.marked.isEmpty)
                }
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 315)
            .searchable(text: $query, placement: .sidebar, prompt: "Find photos or keywords")
        } detail: {
            VStack(spacing: 0) {
                if let entry = photos.first(where: { $0.id == workspace.selection }) {
                    PhotoInspector(entry: entry, workspace: workspace)
                        .id(entry.id)
                } else {
                    ContentUnavailableView {
                        Label("Choose photos to review", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Open a folder, read Apple Photos, or load a saved review.")
                    } actions: {
                        Button("Open Folder…", action: workspace.openFolder).buttonStyle(.borderedProminent)
                    }
                }
                if workspace.review != nil || workspace.activity != nil {
                    Divider()
                    HStack {
                        if let activity = workspace.activity {
                            ProgressView().controlSize(.small)
                            Text(activity)
                        } else {
                            Text(workspace.status)
                        }
                        Spacer()
                        if let issues = workspace.review?.issues, !issues.isEmpty {
                            Button("\(issues.count) issues") { showIssues = true }
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(workspace.sourceName.isEmpty ? "VisionCull" : workspace.sourceName)
        }
        .toolbar {
            ToolbarItemGroup {
                Menu("Open", systemImage: "folder") {
                    Button("Folder…", action: workspace.openFolder).keyboardShortcut("o")
                    Button("Apple Photos…") { photosOptions = true }
                    Button("Saved Review…", action: workspace.openReview)
                    Divider()
                    Toggle("Find Similar Photos", isOn: $workspace.duplicates)
                }
                Button {
                    confirmApproval = true
                } label: {
                    Label("Approve \(workspace.marked.count) Marked", systemImage: "checkmark.circle")
                }
                .disabled(workspace.marked.isEmpty)
                Menu("Export", systemImage: "square.and.arrow.up") {
                    Button("Save Review…", action: workspace.saveReview)
                        .disabled(workspace.review == nil)
                    Divider()
                    Button("XMP to Folder…") { workspace.export(alongside: false) }
                        .disabled(!photos.contains(where: \.approved))
                    Button("XMP Next to Originals…") { confirmAlongside = true }
                        .disabled(!photos.contains(where: \.approved) || photos.contains { $0.approved && $0.fromApplePhotos })
                }
            }
        }
        .disabled(workspace.activity != nil)
        .sheet(isPresented: $photosOptions) { photosSheet }
        .sheet(isPresented: $showIssues) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Scan Issues").font(.headline)
                List(Array((workspace.review?.issues ?? []).enumerated()), id: \.offset) { row in
                    VStack(alignment: .leading) {
                        Text(row.element.path).fontWeight(.medium).textSelection(.enabled)
                        Text(row.element.message).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Button("Done") { showIssues = false }.keyboardShortcut(.defaultAction)
            }
            .padding().frame(width: 620, height: 400)
        }
        .confirmationDialog("Approve \(workspace.marked.count) marked photos?", isPresented: $confirmApproval, titleVisibility: .visible) {
            Button("Approve Marked", action: workspace.approveMarked)
        } message: {
            Text("Approved metadata is eligible for XMP export and optional Immich actions.")
        }
        .confirmationDialog("Write XMP sidecars next to the originals?", isPresented: $confirmAlongside, titleVisibility: .visible) {
            Button("Write Sidecars") { workspace.export(alongside: true) }
        }
        .alert("VisionCull", isPresented: Binding(get: { workspace.alert != nil }, set: { if !$0 { workspace.alert = nil } })) {
            Button("OK", role: .cancel) { workspace.alert = nil }
        } message: {
            Text(workspace.alert ?? "")
        }
    }

    private var photosSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Read Apple Photos").font(.title2)
            Stepper("Most recent \(workspace.photosLimit) images", value: $workspace.photosLimit, in: 10...500, step: 10)
            Toggle("Download iCloud-only originals", isOn: $workspace.allowICloud)
            Text("VisionCull reads still-image originals into its local cache. XMP exports go to a folder you choose.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { photosOptions = false }.keyboardShortcut(.cancelAction)
                Button("Scan Library") {
                    photosOptions = false
                    workspace.openPhotos()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 440)
    }
}

@MainActor
private struct PhotoInspector: View {
    let entry: PhotoEntry
    @ObservedObject var workspace: Workspace
    @State private var draft: PhotoMetadata
    @State private var keywords: String
    @State private var latitude: String
    @State private var longitude: String
    @State private var showImmich = false

    init(entry: PhotoEntry, workspace: Workspace) {
        self.entry = entry
        self.workspace = workspace
        _draft = State(initialValue: entry.metadata)
        _keywords = State(initialValue: entry.metadata.subjects.joined(separator: ", "))
        _latitude = State(initialValue: Self.coordinate(entry.metadata.latitude))
        _longitude = State(initialValue: Self.coordinate(entry.metadata.longitude))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.file.lastPathComponent).font(.title2.bold()).textSelection(.enabled)
                    Text(entry.relativePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Thumbnail(url: entry.file, pixels: 1400)
                    .frame(maxWidth: .infinity).frame(height: 330)
                    .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
                if let group = workspace.matches[entry.id] {
                    Text("Similar Photos").font(.headline)
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(group.compactMap { id in workspace.review?.photos.first { $0.id == id } }) { match in
                                Button { workspace.selection = match.id } label: {
                                    VStack {
                                        Thumbnail(url: match.file, pixels: 270).frame(width: 112, height: 76)
                                        Text(match.file.lastPathComponent).font(.caption).lineLimit(1)
                                    }.frame(width: 112)
                                }
                                .buttonStyle(.plain)
                                .disabled(match.id == entry.id)
                            }
                        }
                    }
                }
                HStack {
                    Text("Metadata").font(.headline)
                    Spacer()
                    if let score = entry.analysis.aestheticScore {
                        Text("Vision score \(score, format: .number.precision(.fractionLength(2)))")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    GridRow {
                        Text("Motifs")
                        TextField("Comma-separated keywords", text: $keywords).labelsHidden()
                    }
                    GridRow {
                        Text("Category")
                        TextField("Category", text: $draft.category).labelsHidden()
                    }
                    GridRow {
                        Text("Description")
                        TextField("Short description", text: $draft.description, axis: .vertical)
                            .labelsHidden().lineLimit(2...4)
                    }
                    GridRow {
                        Text("Capture date")
                        TextField("YYYY-MM-DD or YYYY-MM-DDThh:mm:ss±hh:mm", text: $draft.capturedAt).labelsHidden()
                    }
                    GridRow {
                        Text("GPS")
                        HStack {
                            TextField("Latitude", text: $latitude)
                            TextField("Longitude", text: $longitude)
                        }
                    }
                }
                HStack {
                    Button("Use Original Metadata") { reset(to: entry.existing) }
                    Button("Save Edits", action: save).buttonStyle(.borderedProminent).disabled(!dirty)
                    Spacer()
                    if entry.approved {
                        Button("Revoke Approval") { workspace.revoke(entry.id) }
                    }
                    Button("Send to Immich…") { showImmich = true }
                        .disabled(!entry.approved || dirty)
                }
                if dirty {
                    Text("Save edits before approval. Saving a change clears prior approval.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 840).padding(24)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showImmich) { ImmichSheet(photo: entry) }
    }

    private var dirty: Bool {
        draft != entry.metadata || keywords != entry.metadata.subjects.joined(separator: ", ")
            || latitude != Self.coordinate(entry.metadata.latitude) || longitude != Self.coordinate(entry.metadata.longitude)
    }

    private func save() {
        do {
            var value = draft
            value.subjects = keywords.components(separatedBy: ",")
            let lat = latitude.trimmingCharacters(in: .whitespacesAndNewlines)
            let lon = longitude.trimmingCharacters(in: .whitespacesAndNewlines)
            value.latitude = lat.isEmpty ? nil : Double(lat)
            value.longitude = lon.isEmpty ? nil : Double(lon)
            if (!lat.isEmpty && value.latitude == nil) || (!lon.isEmpty && value.longitude == nil) {
                throw WorkflowError.message("Enter decimal GPS coordinates, using a dot as the decimal separator.")
            }
            let updated = try workspace.apply(value, to: entry.id)
            reset(to: updated.metadata)
        } catch { workspace.alert = error.localizedDescription }
    }

    private static func coordinate(_ value: Double?) -> String {
        value.map { String($0) } ?? ""
    }

    private func reset(to value: PhotoMetadata) {
        draft = value
        keywords = value.subjects.joined(separator: ", ")
        latitude = Self.coordinate(value.latitude)
        longitude = Self.coordinate(value.longitude)
    }
}

private struct Thumbnail: View {
    let url: URL
    let pixels: Int
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            let result = await Task.detached(priority: .utility) {
                let options = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil as CGImage? }
                let resize = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels,
                ] as CFDictionary
                return CGImageSourceCreateThumbnailAtIndex(source, 0, resize)
            }.value
            if !Task.isCancelled { image = result }
        }
    }
}

@MainActor
private struct ImmichSheet: View {
    enum Action: String, CaseIterable {
        case update = "Update Existing"
        case upload = "Upload New"
    }

    let photo: PhotoEntry
    @Environment(\.dismiss) private var dismiss
    @State private var action: Action = .update
    @State private var server = ""
    @State private var key = ""
    @State private var asset = ""
    @State private var album = ""
    @State private var confirmed = false
    @State private var busy = false
    @State private var completed = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send to Immich").font(.title2)
            Text(photo.file.lastPathComponent).font(.headline)
            Picker("Action", selection: $action) {
                ForEach(Action.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            TextField("Immich HTTPS URL", text: $server)
            SecureField("Immich API key", text: $key)
            if action == .update { TextField("Verified asset UUID", text: $asset) }
            TextField(action == .upload ? "Target album UUID" : "Album UUID (optional)", text: $album)
            Text(action == .upload
                ? "Only this image is uploaded. If Immich has matching bytes, review the returned asset ID before updating."
                : "The asset ID must match the local image checksum. If you're unsure, verify the original in Immich first.")
                .foregroundStyle(.secondary)
            if let message { Text(message).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(completed ? "Done" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(busy)
                if !completed {
                    Button("Review Action…") { confirmed = true }
                        .disabled(busy || server.isEmpty || key.isEmpty || (action == .upload ? album.isEmpty : asset.isEmpty))
                }
            }
        }
        .padding(24).frame(width: 490)
        .interactiveDismissDisabled(busy)
        .confirmationDialog(
            action == .upload ? "Upload this original to Immich?" : "Update this Immich asset?",
            isPresented: $confirmed, titleVisibility: .visible
        ) {
            Button(action == .upload ? "Upload Image" : "Update Asset", action: run)
        } message: {
            Text(action == .upload ? "This sends \(photo.file.lastPathComponent) to album \(album)." : "Asset ID: \(asset)")
        }
    }

    private func run() {
        let albumText = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              albumText.isEmpty || UUID(uuidString: albumText) != nil else {
            message = "Check the server URL and album UUID."
            return
        }
        let selectedAlbum = UUID(uuidString: albumText)
        let selectedAsset = UUID(uuidString: asset.trimmingCharacters(in: .whitespacesAndNewlines))
        let action = action
        do {
            let client = try ImmichClient(server: url, apiKey: key)
            busy = true
            message = nil
            Task {
                defer { busy = false }
                do {
                    switch action {
                    case .update:
                        guard let selectedAsset else { throw WorkflowError.message("Enter the exact asset UUID.") }
                        try await client.update(photo, assetID: selectedAsset, addToAlbum: selectedAlbum)
                        message = "Updated asset \(selectedAsset)."
                    case .upload:
                        guard let selectedAlbum else { throw WorkflowError.message("Enter a target album UUID.") }
                        let new = try await client.upload(photo, album: selectedAlbum)
                        message = "Uploaded asset \(new) and added it to the target album."
                    }
                    completed = true
                    key = ""
                } catch { message = error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
    }
}
#else
@main
struct VisionCullApp {
    static func main() {
        FileHandle.standardError.write(Data("The native VisionCull app requires macOS 15 or later.\n".utf8))
    }
}
#endif
