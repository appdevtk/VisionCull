#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VisionCullCore

@MainActor
struct SavedSearchPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var preferences: ReviewPreferences
    let apply: (SavedSearch?) -> Void
    @State private var selected: UUID?
    @State private var name = ""
    @State private var text = ""
    @State private var topics = ""
    @State private var moods = ""
    @State private var styles = ""
    @State private var stars = 0
    @State private var issue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Saved Searches").font(.title2.bold())
            Picker("Search", selection: $selected) {
                Text("New Search").tag(nil as UUID?)
                ForEach(preferences.searches) { item in Text(item.name).tag(item.id as UUID?) }
            }
            .onChange(of: selected) { _, id in load(id) }
            Form {
                TextField("Name", text: $name)
                TextField("Text", text: $text)
                TextField("Topics (comma-separated)", text: $topics)
                TextField("Moods (comma-separated)", text: $moods)
                TextField("Styles (comma-separated)", text: $styles)
                Picker("Minimum stars", selection: $stars) {
                    Text("Any rating").tag(0)
                    ForEach(1...5, id: \.self) { count in Text("\(count)").tag(count) }
                }
            }
            if !issue.isEmpty { Text(issue).foregroundStyle(.red) }
            HStack {
                Button("Remove", role: .destructive) { remove() }.disabled(selected == nil)
                Button("Clear Active Filter") { apply(nil); dismiss() }
                Spacer()
                Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Apply Filter") { apply(draft); dismiss() }.keyboardShortcut(.defaultAction)
                Button("Done") { dismiss() }
            }
        }
        .padding(24).frame(width: 620)
    }

    private var draft: SavedSearch {
        SavedSearch(id: selected ?? UUID(), name: name.isEmpty ? "Custom Filter" : name,
                    query: ReviewFilterQuery(text: text, topics: tagList(topics), moods: tagList(moods), styles: tagList(styles), minimumStars: stars))
    }

    private func load(_ id: UUID?) {
        let entry = preferences.searches.first { $0.id == id }
        name = entry?.name ?? ""
        text = entry?.query.text ?? ""
        topics = entry?.query.topics.joined(separator: ", ") ?? ""
        moods = entry?.query.moods.joined(separator: ", ") ?? ""
        styles = entry?.query.styles.joined(separator: ", ") ?? ""
        stars = entry?.query.minimumStars ?? 0
    }

    private func save() {
        do {
            preferences = try ReviewLibrary().save(draft)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            selected = preferences.searches.first { $0.name == trimmed }?.id
            issue = ""
        } catch { issue = error.localizedDescription }
    }

    private func remove() {
        guard let selected else { return }
        do {
            preferences = try ReviewLibrary().removeSearch(selected)
            self.selected = nil
            issue = ""
        } catch { issue = error.localizedDescription }
    }
}

@MainActor
struct TagAliasPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var preferences: ReviewPreferences
    let photos: [PhotoEntry]
    @State private var group: TagGroup = .moods
    @State private var alias = ""
    @State private var preferred = ""
    @State private var server = ""
    @State private var key = ""
    @State private var pairs = [TagSimilarity]()
    @State private var checked = false
    @State private var issue = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tag Synonyms").font(.title2.bold())
            HStack {
                Picker("Group", selection: $group) {
                    ForEach(TagGroup.allCases, id: \.self) { value in Text(value.rawValue).tag(value) }
                }
                TextField("Alias", text: $alias)
                TextField("Preferred name", text: $preferred)
                Button("Save Alias", action: save).disabled(alias.isEmpty || preferred.isEmpty)
            }
            List(preferences.aliases) { rule in
                HStack {
                    Text(rule.group.rawValue).foregroundStyle(.secondary)
                    Text("\(rule.alias) → \(rule.preferred)")
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { remove(rule) }.labelStyle(.iconOnly)
                }
            }.frame(height: 125)
            Text("Possible Duplicate Tags").font(.headline)
            HStack {
                Button("Check Current Review", action: checkReview).disabled(photos.isEmpty)
                TextField("Immich HTTPS URL", text: $server)
                SecureField("API key", text: $key)
                Button("Check Immich", action: checkServer).disabled(server.isEmpty || key.isEmpty)
            }
            if checked && pairs.isEmpty { Text("No similar tag pairs found.").foregroundStyle(.secondary) }
            List(pairs) { pair in
                HStack {
                    Text(pair.group.rawValue).foregroundStyle(.secondary)
                    Text("\(pair.first) · \(pair.second)")
                    Spacer()
                    Button("Use as Alias") {
                        group = pair.group
                        alias = leaf(pair.first)
                        preferred = leaf(pair.second)
                    }
                }
            }.frame(height: 180)
            if !issue.isEmpty { Text(issue).foregroundStyle(.red) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 770)
        .disabled(busy).interactiveDismissDisabled(busy)
    }

    private func leaf(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }

    private func save() {
        do {
            preferences = try ReviewLibrary().save(TagAlias(group: group, alias: alias, preferred: preferred))
            alias = ""
            preferred = ""
            issue = ""
        } catch { issue = error.localizedDescription }
    }

    private func remove(_ rule: TagAlias) {
        do {
            preferences = try ReviewLibrary().removeAlias(rule.id)
            issue = ""
        } catch { issue = error.localizedDescription }
    }

    private func checkReview() {
        let aliases = preferences.aliases
        let input = photos
        busy = true
        Task {
            pairs = await Task.detached { TagInventory.similar(in: input, aliases: aliases) }.value
            checked = true
            issue = ""
            busy = false
        }
    }

    private func checkServer() {
        busy = true
        Task {
            defer { busy = false }
            do {
                guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)) else { throw WorkflowError.message("Enter an Immich URL.") }
                let client = try ImmichClient(server: url, apiKey: key, aliases: preferences.aliases)
                pairs = try await client.similarTags()
                checked = true
                issue = ""
            } catch { issue = error.localizedDescription }
        }
    }
}

@MainActor
struct BatchEditPanel: View {
    @Environment(\.dismiss) private var dismiss
    let count: Int
    let apply: (BatchMetadataEdit) throws -> Void
    @State private var topics = ""
    @State private var moods = ""
    @State private var styles = ""
    @State private var stars = -1
    @State private var issue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit \(count) Marked Photos").font(.title2.bold())
            Form {
                TextField("Add topics (comma-separated)", text: $topics)
                TextField("Add moods (comma-separated)", text: $moods)
                TextField("Add styles (comma-separated)", text: $styles)
                Picker("Rating", selection: $stars) {
                    Text("Keep current rating").tag(-1)
                    Text("Clear rating").tag(0)
                    ForEach(1...5, id: \.self) { count in Text("\(count) stars").tag(count) }
                }
            }
            Text("Changed photos go back to Pending for approval.").foregroundStyle(.secondary)
            if !issue.isEmpty { Text(issue).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply Edits") {
                    do {
                        try apply(BatchMetadataEdit(topics: tagList(topics), moods: tagList(moods), styles: tagList(styles), rating: stars < 0 ? nil : stars))
                        dismiss()
                    } catch { issue = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 560)
    }
}

func tagList(_ value: String) -> [String] {
    value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}
#endif
