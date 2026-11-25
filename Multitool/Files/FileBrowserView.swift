import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @EnvironmentObject private var sessions: SessionManager
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model: FileBrowserModel

    @State private var search = ""
    @State private var showImporter = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showNewFile = false
    @State private var newFileName = ""
    @State private var renameTarget: RemoteFile?
    @State private var renameText = ""
    @State private var deleteTarget: RemoteFile?
    @State private var chmodTarget: RemoteFile?
    @State private var editorTarget: RemoteFile?
    @State private var preview: URLItem?
    @State private var showGoTo = false
    @State private var goToPath = ""

    init(host: ServerHost, password: String?, store: AppStore, startPath: String? = nil) {
        _model = StateObject(wrappedValue: FileBrowserModel(host: host, password: password, store: store, startPath: startPath))
    }

    private var filteredItems: [RemoteFile] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.visibleItems }
        return model.visibleItems.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        withDialogs(withPickers(baseView))
    }

    private var baseView: some View {
        content
            .navigationTitle(model.host.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.phase == .ready {
                    PathBar(path: model.path) { newPath in
                        Task { await model.load(newPath) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TransfersPanel(model: model)
            }
            .task { await model.start() }
            .onDisappear { model.close() }
    }

    private func withPickers<V: View>(_ view: V) -> some View {
        view
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task { await model.upload(urls) }
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, matching: .any(of: [.images, .videos]))
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                let selected = items
                photoItems = []
                Task { await uploadPhotos(selected) }
            }
            .sheet(item: $chmodTarget) { item in
                ChmodSheet(item: item) { mode in
                    Task { await model.chmod(item, mode: mode) }
                }
            }
            .sheet(item: $editorTarget) { item in
                NavigationStack {
                    FileEditorView(model: model, file: item)
                }
            }
            .sheet(item: $preview) { item in
                QuickLookView(url: item.url)
                    .ignoresSafeArea()
            }
    }

    private func withDialogs<V: View>(_ view: V) -> some View {
        view
            .alert("Nowy folder", isPresented: $showNewFolder) {
                TextField("Nazwa folderu", text: $newFolderName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Utwórz") {
                    let name = newFolderName
                    Task { await model.makeDirectory(named: name) }
                }
                Button("Anuluj", role: .cancel) {}
            }
            .alert("Nowy plik", isPresented: $showNewFile) {
                TextField("nazwa.txt", text: $newFileName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Utwórz") {
                    let name = newFileName
                    Task { await model.makeFile(named: name) }
                }
                Button("Anuluj", role: .cancel) {}
            }
            .alert("Zmień nazwę", isPresented: isPresented($renameTarget), presenting: renameTarget) { item in
                TextField("Nowa nazwa", text: $renameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Zapisz") {
                    let newName = renameText
                    Task { await model.rename(item, to: newName) }
                }
                Button("Anuluj", role: .cancel) {}
            }
            .alert("Przejdź do ścieżki", isPresented: $showGoTo) {
                TextField("/ścieżka/do/katalogu", text: $goToPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Przejdź") {
                    let target = goToPath
                    Task { await model.load(target) }
                }
                Button("Anuluj", role: .cancel) {}
            }
            .confirmationDialog("Usunąć?", isPresented: isPresented($deleteTarget), titleVisibility: .visible, presenting: deleteTarget) { item in
                Button("Usuń „\(item.name)”", role: .destructive) {
                    Task { await model.delete(item) }
                }
            } message: { item in
                Text(item.isDirectory ? "Folder zostanie usunięty razem z całą zawartością." : "Tej operacji nie można cofnąć.")
            }
            .alert("Błąd", isPresented: messageBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.message ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .connecting:
            ProgressView("Łączenie z \(model.host.displayName)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Nie udało się połączyć", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Spróbuj ponownie") {
                    Task { await model.retry() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .ready:
            fileList
        }
    }

    private var fileList: some View {
        List {
            if model.path != "/" {
                Button {
                    Task { await model.goUp() }
                } label: {
                    Label("..", systemImage: "arrow.turn.left.up")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(filteredItems) { item in
                FileRow(item: item)
                    .contentShape(Rectangle())
                    .onTapGesture { open(item) }
                    .contextMenu { menu(for: item) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteTarget = item
                        } label: {
                            Label("Usuń", systemImage: "trash")
                        }
                        Button {
                            startRename(item)
                        } label: {
                            Label("Nazwa", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
            }
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
        .searchable(text: $search, prompt: "Filtruj w tym folderze")
        .overlay {
            if model.isLoading && model.items.isEmpty {
                ProgressView()
            } else if !model.isLoading && filteredItems.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("Pusty folder", systemImage: "folder")
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for item: RemoteFile) -> some View {
        if item.isDirectory {
            Button {
                Task { await model.load(item.path) }
            } label: {
                Label("Otwórz", systemImage: "folder")
            }
            if model.canUseShell {
                Button {
                    openTerminal(at: item.path)
                } label: {
                    Label("Terminal w tym folderze", systemImage: "apple.terminal")
                }
            }
        } else {
            Button {
                Task { await downloadAndPreview(item) }
            } label: {
                Label("Pobierz i otwórz", systemImage: "arrow.down.circle")
            }
            Button {
                editorTarget = item
            } label: {
                Label("Edytuj jako tekst", systemImage: "pencil.and.outline")
            }
        }
        Button {
            startRename(item)
        } label: {
            Label("Zmień nazwę", systemImage: "pencil")
        }
        Button {
            chmodTarget = item
        } label: {
            Label("Uprawnienia (chmod)", systemImage: "lock.shield")
        }
        Button {
            UIPasteboard.general.string = item.path
        } label: {
            Label("Kopiuj ścieżkę", systemImage: "doc.on.doc")
        }
        if model.canUseShell {
            let archiveExtensions: Set<String> = ["zip", "gz", "tgz", "tar", "bz2", "xz"]
            if archiveExtensions.contains(item.fileExtension) {
                Button {
                    Task { await model.extract(item) }
                } label: {
                    Label("Rozpakuj tutaj", systemImage: "archivebox")
                }
            } else {
                Button {
                    Task { await model.compress(item) }
                } label: {
                    Label("Spakuj (.tar.gz)", systemImage: "archivebox")
                }
            }
        }
        Divider()
        Button(role: .destructive) {
            deleteTarget = item
        } label: {
            Label("Usuń", systemImage: "trash")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button {
                    showImporter = true
                } label: {
                    Label("Wyślij pliki", systemImage: "square.and.arrow.up")
                }
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("Wyślij zdjęcia / wideo", systemImage: "photo.on.rectangle")
                }
                Divider()
                Button {
                    newFolderName = ""
                    showNewFolder = true
                } label: {
                    Label("Nowy folder", systemImage: "folder.badge.plus")
                }
                Button {
                    newFileName = ""
                    showNewFile = true
                } label: {
                    Label("Nowy plik", systemImage: "doc.badge.plus")
                }
            } label: {
                Image(systemName: "plus.circle")
            }
            .disabled(model.phase != .ready)

            Menu {
                Picker("Sortowanie", selection: $model.sort) {
                    ForEach(FileBrowserModel.SortMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Pokaż ukryte pliki", isOn: $model.showHidden)
                Divider()
                Button {
                    goToPath = model.path
                    showGoTo = true
                } label: {
                    Label("Przejdź do ścieżki…", systemImage: "arrow.right.circle")
                }
                Button {
                    UIPasteboard.general.string = model.path
                } label: {
                    Label("Kopiuj bieżącą ścieżkę", systemImage: "doc.on.doc")
                }
                if model.canUseShell {
                    Button {
                        openTerminal(at: model.path)
                    } label: {
                        Label("Terminal w tym folderze", systemImage: "apple.terminal")
                    }
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Odśwież", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(model.phase != .ready)
        }
    }

    private var messageBinding: Binding<Bool> {
        Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )
    }

    private func isPresented<T>(_ binding: Binding<T?>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue != nil },
            set: { if !$0 { binding.wrappedValue = nil } }
        )
    }

    private func open(_ item: RemoteFile) {
        if item.isDirectory {
            Task { await model.load(item.path) }
        } else if item.isLikelyText {
            editorTarget = item
        } else {
            Task { await downloadAndPreview(item) }
        }
    }

    private func startRename(_ item: RemoteFile) {
        renameText = item.name
        renameTarget = item
    }

    private func downloadAndPreview(_ item: RemoteFile) async {
        if let url = await model.download(item) {
            preview = URLItem(url: url)
        }
    }

    private func openTerminal(at path: String) {
        sessions.open(model.host, password: nil, initialDirectory: path)
        router.tab = .terminal
    }

    private func uploadPhotos(_ items: [PhotosPickerItem]) async {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            let name = "IMG_\(formatter.string(from: Date()))_\(index + 1).\(ext)"
            await model.upload(data: data, named: name)
        }
    }
}

struct FileRow: View {
    let item: RemoteFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.iconName)
                .font(.title3)
                .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isSymlink {
                        Image(systemName: "arrow.uturn.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !item.detailLine.isEmpty {
                    Text(item.detailLine)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct PathBar: View {
    let path: String
    let onSelect: (String) -> Void

    var body: some View {
        let crumbs = RemotePath.breadcrumbs(path)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button(crumb.name) { onSelect(crumb.path) }
                            .font(.footnote.monospaced())
                            .buttonStyle(.plain)
                            .foregroundStyle(index == crumbs.count - 1 ? Color.primary : Color.secondary)
                            .id(index)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(crumbs.count - 1, anchor: .trailing) }
            .onChange(of: path) { _, _ in
                proxy.scrollTo(RemotePath.breadcrumbs(path).count - 1, anchor: .trailing)
            }
        }
        .background(.bar)
    }
}

struct TransfersPanel: View {
    @ObservedObject var model: FileBrowserModel

    var body: some View {
        if !model.transfers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Transfery")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Wyczyść") { model.clearFinishedTransfers() }
                        .font(.caption)
                        .disabled(!model.transfers.contains { $0.finished })
                }
                ForEach(model.transfers.suffix(3)) { transfer in
                    TransferRow(transfer: transfer)
                }
            }
            .padding(12)
            .background(.regularMaterial)
        }
    }
}

struct TransferRow: View {
    let transfer: FileBrowserModel.Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: transfer.isUpload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(transfer.error != nil ? Color.red : (transfer.finished ? Color.green : Color.accentColor))
                Text(transfer.name)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(statusText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !transfer.finished {
                if let fraction = transfer.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
        }
    }

    private var statusText: String {
        if let error = transfer.error { return error }
        if transfer.finished { return "Gotowe" }
        if let total = transfer.total { return "\(Fmt.bytes(transfer.done)) / \(Fmt.bytes(total))" }
        return Fmt.bytes(transfer.done)
    }
}
