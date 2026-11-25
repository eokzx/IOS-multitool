import SwiftUI

enum HostRoute: Hashable {
    case files(ServerHost, String?)
    case monitor(ServerHost, String?)
}

enum HostAction {
    case terminal
    case files
    case monitor
}

struct HostsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var sessions: SessionManager
    @EnvironmentObject private var router: AppRouter

    @State private var search = ""
    @State private var path: [HostRoute] = []
    @State private var editing: ServerHost?
    @State private var passwordRequest: PasswordRequest?
    @State private var hostToDelete: ServerHost?

    private var filteredHosts: [ServerHost] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let base = query.isEmpty ? store.hosts : store.hosts.filter { $0.matches(query) }
        return base.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var favorites: [ServerHost] {
        filteredHosts.filter(\.isFavorite)
    }

    private var groupedHosts: [ServerHost] {
        filteredHosts.filter { !$0.isFavorite }
    }

    private var groups: [String] {
        Array(Set(groupedHosts.map(\.group))).sorted { a, b in
            if a.isEmpty { return false }
            if b.isEmpty { return true }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !favorites.isEmpty {
                    Section("Ulubione") {
                        ForEach(favorites) { host in
                            row(host)
                        }
                    }
                }
                ForEach(groups, id: \.self) { group in
                    Section(group.isEmpty ? "Serwery" : group) {
                        ForEach(groupedHosts.filter { $0.group == group }) { host in
                            row(host)
                        }
                    }
                }
            }
            .overlay { emptyState }
            .searchable(text: $search, prompt: "Szukaj serwerów")
            .navigationTitle("Serwery")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            editing = ServerHost()
                        } label: {
                            Label("Nowy serwer", systemImage: "plus")
                        }
                        Button {
                            router.quickConnect = QuickConnectDraft()
                        } label: {
                            Label("Szybkie połączenie", systemImage: "bolt.fill")
                        }
                        Button {
                            router.tab = .tailscale
                        } label: {
                            Label("Importuj z Tailscale", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: HostRoute.self) { route in
                destination(route)
            }
            .sheet(item: $editing) { host in
                HostEditorView(host: host)
            }
            .sheet(item: $router.quickConnect) { draft in
                QuickConnectView(draft: draft) { host, password in
                    path.append(.files(host, password))
                }
            }
            .passwordPrompt($passwordRequest, store: store)
            .confirmationDialog(
                "Usunąć serwer?",
                isPresented: Binding(get: { hostToDelete != nil }, set: { if !$0 { hostToDelete = nil } }),
                titleVisibility: .visible,
                presenting: hostToDelete
            ) { host in
                Button("Usuń „\(host.displayName)”", role: .destructive) {
                    store.delete(host)
                }
            } message: { _ in
                Text("Zapisane hasło zostanie usunięte z pęku kluczy.")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.hosts.isEmpty {
            ContentUnavailableView {
                Label("Brak serwerów", systemImage: "server.rack")
            } description: {
                Text("Dodaj serwer SSH, SFTP lub FTP. Możesz też zaimportować urządzenia ze swojej sieci Tailscale.")
            } actions: {
                Button("Dodaj serwer") { editing = ServerHost() }
                    .buttonStyle(.borderedProminent)
                Button("Szybkie połączenie") { router.quickConnect = QuickConnectDraft() }
            }
        } else if filteredHosts.isEmpty {
            ContentUnavailableView.search(text: search)
        }
    }

    private func row(_ host: ServerHost) -> some View {
        Button {
            perform(host.kind == .ssh ? .terminal : .files, on: host)
        } label: {
            HostRow(host: host, activeSessions: sessions.count(for: host.id))
        }
        .contextMenu { actions(for: host) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                hostToDelete = host
            } label: {
                Label("Usuń", systemImage: "trash")
            }
            Button {
                editing = host
            } label: {
                Label("Edytuj", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .leading) {
            if host.kind == .ssh {
                Button {
                    perform(.files, on: host)
                } label: {
                    Label("Pliki", systemImage: "folder")
                }
                .tint(.indigo)
            }
            Button {
                store.toggleFavorite(host)
            } label: {
                Label("Ulubiony", systemImage: host.isFavorite ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
    }

    @ViewBuilder
    private func actions(for host: ServerHost) -> some View {
        if host.kind == .ssh {
            Button {
                perform(.terminal, on: host)
            } label: {
                Label("Terminal", systemImage: "apple.terminal")
            }
            Button {
                perform(.files, on: host)
            } label: {
                Label("Pliki (SFTP)", systemImage: "folder")
            }
            Button {
                perform(.monitor, on: host)
            } label: {
                Label("Monitor serwera", systemImage: "chart.xyaxis.line")
            }
        } else {
            Button {
                perform(.files, on: host)
            } label: {
                Label("Przeglądaj pliki", systemImage: "folder")
            }
        }
        Divider()
        Button {
            editing = host
        } label: {
            Label("Edytuj", systemImage: "pencil")
        }
        Button {
            store.duplicate(host)
        } label: {
            Label("Duplikuj", systemImage: "plus.square.on.square")
        }
        Button {
            store.toggleFavorite(host)
        } label: {
            Label(host.isFavorite ? "Usuń z ulubionych" : "Dodaj do ulubionych", systemImage: host.isFavorite ? "star.slash" : "star")
        }
        if host.kind == .ssh {
            Button {
                UIPasteboard.general.string = host.sshCommand
            } label: {
                Label("Kopiuj polecenie ssh", systemImage: "doc.on.doc")
            }
        }
        Divider()
        Button(role: .destructive) {
            hostToDelete = host
        } label: {
            Label("Usuń", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func destination(_ route: HostRoute) -> some View {
        switch route {
        case .files(let host, let password):
            FileBrowserView(host: host, password: password, store: store)
        case .monitor(let host, let password):
            ServerMonitorView(host: host, password: password, store: store)
        }
    }

    private func perform(_ action: HostAction, on host: ServerHost) {
        if ConnectionHelper.needsPassword(host, store: store) {
            passwordRequest = PasswordRequest(host: host) { password in
                execute(action, on: host, password: password)
            }
        } else {
            execute(action, on: host, password: nil)
        }
    }

    private func execute(_ action: HostAction, on host: ServerHost, password: String?) {
        switch action {
        case .terminal:
            sessions.open(host, password: password)
            router.tab = .terminal
        case .files:
            path.append(.files(host, password))
        case .monitor:
            path.append(.monitor(host, password))
        }
    }
}
