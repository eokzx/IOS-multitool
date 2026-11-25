import SwiftUI

struct SnippetsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var editing: Snippet?

    var body: some View {
        List {
            ForEach(store.snippets) { snippet in
                Button {
                    editing = snippet
                } label: {
                    SnippetRow(snippet: snippet)
                }
            }
            .onDelete { offsets in
                store.snippets.remove(atOffsets: offsets)
            }
            .onMove { source, destination in
                store.snippets.move(fromOffsets: source, toOffset: destination)
            }
        }
        .overlay {
            if store.snippets.isEmpty {
                ContentUnavailableView(
                    "Brak snippetów",
                    systemImage: "text.badge.plus",
                    description: Text("Zapisz często używane polecenia i wysyłaj je do terminala jednym dotknięciem.")
                )
            }
        }
        .navigationTitle("Snippety")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                Button {
                    editing = Snippet(name: "", command: "")
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editing) { snippet in
            SnippetEditor(snippet: snippet)
        }
    }
}

struct SnippetRow: View {
    let snippet: Snippet

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(snippet.name.isEmpty ? "Bez nazwy" : snippet.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if !snippet.runImmediately {
                    Image(systemName: "pencil.line")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(snippet.command)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

struct SnippetEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Snippet

    init(snippet: Snippet) {
        _draft = State(initialValue: snippet)
    }

    private var isNew: Bool { !store.snippets.contains { $0.id == draft.id } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nazwa") {
                    TextField("np. Restart nginx", text: $draft.name)
                }
                Section {
                    TextField("sudo systemctl restart nginx", text: $draft.command, axis: .vertical)
                        .font(.body.monospaced())
                        .lineLimit(3...12)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Polecenie")
                }
                Section {
                    Toggle("Wykonaj od razu (Enter)", isOn: $draft.runImmediately)
                } footer: {
                    Text("Gdy wyłączone, polecenie zostanie tylko wpisane do terminala — możesz je poprawić przed wykonaniem.")
                }
            }
            .navigationTitle(isNew ? "Nowy snippet" : "Edytuj snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zapisz") {
                        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
                            draft.name = String(draft.command.prefix(30))
                        }
                        store.upsert(draft)
                        dismiss()
                    }
                    .disabled(draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct SnippetPicker: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Snippet) -> Void
    @State private var search = ""

    private var filtered: [Snippet] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.snippets }
        return store.snippets.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.command.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { snippet in
                Button {
                    onSelect(snippet)
                    dismiss()
                } label: {
                    SnippetRow(snippet: snippet)
                }
            }
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView("Brak snippetów", systemImage: "text.badge.plus")
                }
            }
            .searchable(text: $search, prompt: "Szukaj")
            .navigationTitle("Snippety")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zamknij") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SnippetsView()
                    } label: {
                        Text("Zarządzaj")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
