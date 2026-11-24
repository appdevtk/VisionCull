#if os(macOS)
import SwiftUI
import VisionCullCore

@MainActor
struct ImmichBatchPanel: View {
    @Environment(\.dismiss) private var dismiss
    let photos: [PhotoEntry]
    let aliases: [TagAlias]
    @State private var server = ""
    @State private var key = ""
    @State private var album = ""
    @State private var overrides = [String: String]()
    @State private var upload = Set<String>()
    @State private var checked = Set<String>()
    @State private var rows = [ImmichBatchPreview]()
    @State private var receipts = [ImmichBatchResult]()
    @State private var client: ImmichClient?
    @State private var busy = false
    @State private var confirm = false
    @State private var issue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Immich Batch Preview").font(.title2.bold())
            HStack {
                TextField("Immich HTTPS URL", text: $server)
                SecureField("API key", text: $key)
                TextField("Album UUID for uploads", text: $album)
            }.disabled(busy)
            Text("Existing items match by file checksum. Choose uploads individually and supply an album.")
                .foregroundStyle(.secondary)
            List(photos) { photo in
                row(photo)
            }.disabled(busy)
            if !issue.isEmpty { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Text("\(checked.count) ready and selected").foregroundStyle(.secondary)
                Spacer()
                Button("Preview", action: prepare).disabled(busy || key.isEmpty || server.isEmpty)
                Button("Send Selected…") { confirm = true }.disabled(busy || checked.isEmpty)
                    .keyboardShortcut(.defaultAction)
                Button("Done") { dismiss() }.disabled(busy)
            }
        }
        .padding(24).frame(width: 920, height: 620)
        .onChange(of: server) { _, _ in changeConnection() }
        .onChange(of: key) { _, _ in changeConnection() }
        .onChange(of: album) { _, _ in invalidate() }
        .interactiveDismissDisabled(busy)
        .confirmationDialog("Send \(checked.count) selected items to Immich?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Send Selected", action: send)
        }
    }

    private func row(_ photo: PhotoEntry) -> some View {
        let row = rows.first { $0.id == photo.id }
        let receipt = receipts.first { $0.id == photo.id }
        let canSelect = row?.isReady == true && receipt == nil
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Toggle("Include \(photo.relativePath)", isOn: Binding(
                    get: { checked.contains(photo.id) },
                    set: { if $0 { checked.insert(photo.id) } else { checked.remove(photo.id) } }
                )).labelsHidden().toggleStyle(.checkbox).disabled(!canSelect)
                Text(photo.relativePath).fontWeight(.medium)
                Spacer()
                Toggle("Upload new", isOn: Binding(
                    get: { upload.contains(photo.id) },
                    set: {
                        if $0 { upload.insert(photo.id) } else { upload.remove(photo.id) }
                        invalidate()
                    }
                )).toggleStyle(.checkbox)
                TextField("Existing asset UUID (optional)", text: Binding(
                    get: { overrides[photo.id] ?? "" },
                    set: { overrides[photo.id] = $0; invalidate() }
                )).frame(width: 250).disabled(upload.contains(photo.id))
            }
            if let receipt {
                if let problem = receipt.problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
                else if let id = receipt.assetID { Text("Sent \(id.uuidString)").foregroundStyle(.green).textSelection(.enabled) }
            } else if let row {
                details(row)
            }
        }.padding(.vertical, 3)
    }

    @ViewBuilder
    private func details(_ row: ImmichBatchPreview) -> some View {
        if let problem = row.problem {
            Text(problem).foregroundStyle(.red).textSelection(.enabled)
        } else {
            if let id = row.assetID { Text("Update \(id.uuidString)").textSelection(.enabled) }
            if let id = row.albumID { Text("Upload to album \(id.uuidString)").textSelection(.enabled) }
            if !row.reusedTags.isEmpty { Text("Reuse: \(row.reusedTags.joined(separator: ", "))") }
            if !row.newTags.isEmpty { Text("Create: \(row.newTags.joined(separator: ", "))") }
            if !row.metadataChanges.isEmpty { Text(row.metadataChanges.joined(separator: " · ")) }
        }
    }

    private func changeConnection() {
        invalidate()
        receipts = []
    }

    private func invalidate() {
        rows = []
        checked = []
        client = nil
    }

    private func prepare() {
        do {
            guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)) else { throw WorkflowError.message("Enter an Immich URL.") }
            let client = try ImmichClient(server: url, apiKey: key, aliases: aliases)
            let albumID = UUID(uuidString: album.trimmingCharacters(in: .whitespaces))
            if !upload.isEmpty && albumID == nil { throw WorkflowError.message("Enter the album UUID for selected uploads.") }
            let requests = try photos.filter { photo in !receipts.contains { $0.id == photo.id && $0.problem == nil } }.map { photo -> ImmichBatchRequest in
                if upload.contains(photo.id), let albumID { return ImmichBatchRequest(photo: photo, intent: .upload(album: albumID)) }
                if let text = overrides[photo.id]?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                    guard let id = UUID(uuidString: text) else { throw WorkflowError.message("\(photo.relativePath): Invalid asset UUID.") }
                    return ImmichBatchRequest(photo: photo, intent: .update(id))
                }
                return ImmichBatchRequest(photo: photo)
            }
            invalidate()
            receipts.removeAll { $0.problem != nil }
            issue = ""
            busy = true
            Task {
                defer { busy = false }
                do {
                    rows = try await client.previewBatch(requests)
                    checked = Set(rows.filter(\.isReady).map(\.id))
                    self.client = client
                } catch { issue = error.localizedDescription }
            }
        } catch { issue = error.localizedDescription }
    }

    private func send() {
        guard let client else { return }
        let confirmed = rows.filter { checked.contains($0.id) && $0.isReady }
        busy = true
        issue = ""
        Task {
            defer { busy = false }
            do {
                receipts += try await client.applyBatch(confirmed)
                checked.subtract(confirmed.map(\.id))
                let processed = Set(confirmed.map(\.id))
                rows.removeAll { processed.contains($0.id) }
            } catch {
                issue = error.localizedDescription
                invalidate()
            }
        }
    }
}
#endif
