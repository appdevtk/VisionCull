#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VisionCullCore

@MainActor
struct ContentSearchPanel: View {
    @Environment(\.dismiss) private var dismiss
    let photos: [PhotoEntry]
    let choose: (Set<String>) -> Void
    @State private var referenceMode = false
    @State private var description = ""
    @State private var reference: URL?
    @State private var results: ContentMatches?
    @State private var checked = Set<String>()
    @State private var task: Task<ContentMatches, Error>?
    @State private var issue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Find Photos by Content").font(.title2.bold())
            Picker("Search by", selection: $referenceMode) {
                Text("Description").tag(false)
                Text("Reference Photo").tag(true)
            }.pickerStyle(.segmented)
            HStack {
                if referenceMode {
                    Button(reference?.lastPathComponent ?? "Choose Reference Photo…", action: chooseReference)
                } else {
                    TextField("e.g. quiet street after rain", text: $description)
                }
                Spacer()
                Button("Search", action: run).disabled(referenceMode ? reference == nil : description.isEmpty)
            }.disabled(task != nil)
            if let results {
                List(results.hits) { hit in
                    HStack {
                        Toggle("Mark \(hit.photo.file.lastPathComponent)", isOn: Binding(
                            get: { checked.contains(hit.id) },
                            set: { if $0 { checked.insert(hit.id) } else { checked.remove(hit.id) } }
                        )).labelsHidden().toggleStyle(.checkbox)
                        Thumbnail(url: hit.photo.file, pixels: 100).frame(width: 65, height: 44)
                        Text(hit.photo.relativePath)
                        Spacer()
                        Text(hit.score, format: .number.precision(.fractionLength(2))).monospacedDigit()
                    }
                }
                if results.hits.isEmpty { Text("No photos matched.").foregroundStyle(.secondary) }
                if !results.issues.isEmpty {
                    DisclosureGroup("\(results.issues.count) skipped files") {
                        ForEach(results.issues.indices, id: \.self) { index in
                            let issue = results.issues[index]
                            Text("\(issue.path): \(issue.message)").font(.caption)
                        }
                    }
                }
            } else {
                Text("Search the current review using local Vision analysis.").foregroundStyle(.secondary)
                Spacer()
            }
            if !issue.isEmpty { Text(issue).foregroundStyle(.red) }
            HStack {
                if task != nil {
                    ProgressView().controlSize(.small)
                    Button("Cancel Search") { task?.cancel() }
                }
                Spacer()
                Button("Done") { dismiss() }.disabled(task != nil)
                Button("Mark Selected Results") { choose(checked); dismiss() }
                    .disabled(checked.isEmpty || task != nil).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 680, height: 585).interactiveDismissDisabled(task != nil)
    }

    private func chooseReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { reference = panel.url }
    }

    private func run() {
        let query = description
        let image = referenceMode ? reference : nil
        let input = photos
        results = nil
        checked.removeAll()
        issue = ""
        let operation = Task.detached(priority: .userInitiated) {
            let search = ContentSearch()
            if let image { return try search.image(image, in: input) }
            return try search.text(query, in: input)
        }
        task = operation
        Task {
            defer { task = nil }
            do { results = try await operation.value }
            catch is CancellationError { issue = "Search cancelled." }
            catch { issue = error.localizedDescription }
        }
    }
}

@MainActor
struct SeriesComparison: View {
    @Environment(\.dismiss) private var dismiss
    let photos: [PhotoEntry]
    let selectFavorite: (String, [String]) -> Void
    let grouped: Bool
    @State private var leftID: String
    @State private var rightID: String
    @State private var favorite: String?
    @State private var confirmedFavorite: String?
    @State private var zoom = 1.0
    @State private var position = CGSize.zero
    @GestureState private var drag = CGSize.zero

    init(photos: [PhotoEntry], starting: String, favorite: String?, grouped: Bool, selectFavorite: @escaping (String, [String]) -> Void) {
        self.photos = photos
        self.selectFavorite = selectFavorite
        self.grouped = grouped
        _leftID = State(initialValue: starting)
        _rightID = State(initialValue: photos.first { $0.id != starting }?.id ?? starting)
        _favorite = State(initialValue: favorite)
        _confirmedFavorite = State(initialValue: photos.first { $0.id == favorite && $0.seriesFavorite == true }?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Compare Photos").font(.title2.bold())
                Spacer()
                Text("Linked Zoom")
                Slider(value: $zoom, in: 1...4).frame(width: 180)
                Text(zoom, format: .number.precision(.fractionLength(1))).monospacedDigit()
                Button("Reset View") { zoom = 1; position = .zero }
            }
            HStack(alignment: .top, spacing: 16) {
                column(selection: $leftID)
                column(selection: $rightID)
            }
            HStack {
                Text("Edge detail is estimated from the preview. Compare it within the same scene.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 1000, height: 680)
        .onChange(of: leftID) { _, _ in refreshManualFavorite() }
        .onChange(of: rightID) { _, _ in refreshManualFavorite() }
    }

    private func refreshManualFavorite() {
        guard !grouped else { return }
        let pair = photos.filter { $0.id == leftID || $0.id == rightID }
        let confirmed = pair.first { $0.seriesFavorite == true }
        confirmedFavorite = confirmed?.id
        favorite = confirmed?.id ?? pair.max {
            ($0.analysis.aestheticScore ?? -.infinity) < ($1.analysis.aestheticScore ?? -.infinity)
        }?.id
    }

    private func column(selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Photo", selection: selection) {
                ForEach(photos) { photo in Text(photo.relativePath).tag(photo.id) }
            }.labelsHidden()
            if let photo = photos.first(where: { $0.id == selection.wrappedValue }) {
                GeometryReader { geometry in
                    let size = geometry.size
                    let x = (position.width + drag.width) * size.width
                    let y = (position.height + drag.height) * size.height
                    Thumbnail(url: photo.file, pixels: 2600).id(photo.id)
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(zoom)
                        .offset(x: clamp(x, extent: size.width), y: clamp(y, extent: size.height))
                        .frame(width: size.width, height: size.height)
                        .background(Color.black.opacity(0.85)).clipped()
                        .gesture(pan(in: size))
                        .accessibilityHidden(true)
                }
                metrics(photo)
                Button {
                    let ids = grouped ? photos.map(\.id) : [leftID, rightID]
                    selectFavorite(photo.id, ids)
                    favorite = photo.id
                    confirmedFavorite = photo.id
                } label: {
                    let label = confirmedFavorite == photo.id ? "Favorite" : favorite == photo.id ? "Confirm Suggested Favorite" : "Set as Favorite"
                    Label(label, systemImage: favorite == photo.id ? "star.fill" : "star")
                }
                .disabled(confirmedFavorite == photo.id)
            }
        }.frame(maxWidth: .infinity)
    }

    private func metrics(_ photo: PhotoEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let score = photo.analysis.aestheticScore {
                Text("Vision \(score, format: .number.precision(.fractionLength(2)))")
            }
            if let look = photo.analysis.appearance {
                if let edges = look.edgeDetail { Text("Edge detail \(edges, format: .number.precision(.fractionLength(3)))") }
                Text("Brightness \(look.brightness, format: .percent.precision(.fractionLength(0)))   Shadows \(look.shadowFraction, format: .percent.precision(.fractionLength(0)))   Highlights \(look.highlightFraction, format: .percent.precision(.fractionLength(0)))")
            }
        }.font(.caption).monospacedDigit()
    }

    private func clamp(_ value: CGFloat, extent: CGFloat) -> CGFloat {
        let limit = extent * (zoom - 1) / 2
        return max(-limit, min(limit, value))
    }

    private func pan(in size: CGSize) -> some Gesture {
        DragGesture().updating($drag) { value, state, _ in
            state = CGSize(width: value.translation.width / max(size.width, 1), height: value.translation.height / max(size.height, 1))
        }.onEnded { value in
            let x = position.width * size.width + value.translation.width
            let y = position.height * size.height + value.translation.height
            position = CGSize(width: clamp(x, extent: size.width) / max(size.width, 1), height: clamp(y, extent: size.height) / max(size.height, 1))
        }
    }
}
#endif
