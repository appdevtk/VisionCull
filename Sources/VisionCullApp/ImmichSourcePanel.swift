#if os(macOS)
import SwiftUI
import VisionCullCore

struct ImmichConnection: Sendable {
    let server: String
    let apiKey: String

    func client(aliases: [TagAlias]) throws -> ImmichClient {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw WorkflowError.message("Enter an Immich URL.")
        }
        return try ImmichClient(server: url, apiKey: apiKey, aliases: aliases)
    }
}

@MainActor
struct ImmichSourcePanel: View {
    @Environment(\.dismiss) private var dismiss
    let aliases: [TagAlias]
    let findSimilar: Bool
    let open: (Review, ImmichAlbum, ImmichConnection) -> Void
    @State private var server = ""
    @State private var key = ""
    @State private var albums = [ImmichAlbum]()
    @State private var selected: UUID?
    @State private var connected = false
    @State private var loading = false
    @State private var scanning: Task<Review, Error>?
    @State private var issue = ""

    init(
        aliases: [TagAlias], findSimilar: Bool, connection: ImmichConnection?,
        open: @escaping (Review, ImmichAlbum, ImmichConnection) -> Void
    ) {
        self.aliases = aliases
        self.findSimilar = findSimilar
        self.open = open
        _server = State(initialValue: connection?.server ?? "")
        _key = State(initialValue: connection?.apiKey ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open Immich Album").font(.title2.bold())
            HStack {
                TextField("Immich HTTPS URL", text: $server)
                SecureField("API key", text: $key)
                Button("Load Albums", action: fetch)
                    .disabled(server.isEmpty || key.isEmpty)
            }.disabled(busy)
            Text("VisionCull downloads previews for local analysis and reads metadata from Immich.")
                .foregroundStyle(.secondary)
            List(albums, selection: $selected) { album in
                HStack {
                    Text(album.albumName)
                    Spacer()
                    Text("\(album.assetCount) assets").foregroundStyle(.secondary)
                }.tag(album.id)
            }.disabled(busy)
            if connected && albums.isEmpty { Text("No albums found for this account.").foregroundStyle(.secondary) }
            if !issue.isEmpty { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                if scanning != nil { Button("Cancel Scan") { scanning?.cancel() } }
                Spacer()
                Button("Cancel") { dismiss() }.disabled(busy).keyboardShortcut(.cancelAction)
                Button("Analyze Previews", action: scan)
                    .disabled(selected == nil || busy).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 720, height: 465)
        .onChange(of: server) { _, _ in resetAlbums() }
        .onChange(of: key) { _, _ in resetAlbums() }
        .interactiveDismissDisabled(busy)
    }

    private var busy: Bool { loading || scanning != nil }
    private var connection: ImmichConnection { ImmichConnection(server: server, apiKey: key) }

    private func resetAlbums() {
        albums = []
        selected = nil
        connected = false
        issue = ""
    }

    private func fetch() {
        do {
            let client = try connection.client(aliases: aliases)
            resetAlbums()
            loading = true
            Task {
                defer { loading = false }
                do {
                    albums = try await client.albums()
                    selected = albums.first?.id
                    connected = true
                } catch { issue = error.localizedDescription }
            }
        } catch { issue = error.localizedDescription }
    }

    private func scan() {
        guard let album = albums.first(where: { $0.id == selected }) else { return }
        do {
            let connection = connection
            let client = try connection.client(aliases: aliases)
            let scanner = PhotoScanner(analyzer: LocalVisionAnalyzer(includeDuplicates: findSimilar))
            issue = ""
            let operation = Task.detached(priority: .userInitiated) { try await client.scanAlbum(album.id, scanner: scanner) }
            scanning = operation
            Task {
                defer { scanning = nil }
                do {
                    let review = try await operation.value
                    open(review, album, connection)
                    dismiss()
                } catch is CancellationError {
                    issue = "Scan cancelled."
                } catch { issue = error.localizedDescription }
            }
        } catch { issue = error.localizedDescription }
    }
}
#endif
