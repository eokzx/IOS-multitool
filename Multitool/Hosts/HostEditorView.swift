import SwiftUI

struct HostEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ServerHost
    @State private var password = ""
    @State private var showPassword = false
    @State private var confirmDelete = false
    @State private var loadedPassword = false

    init(host: ServerHost) {
        _draft = State(initialValue: host)
    }

    private var isNew: Bool { store.host(id: draft.id) == nil }

    private var isValid: Bool {
        !draft.hostname.trimmingCharacters(in: .whitespaces).isEmpty && (1...65_535).contains(draft.port)
    }

    private var jumpCandidates: [ServerHost] {
        store.hosts.filter { $0.kind == .ssh && $0.id != draft.id && $0.jumpHostID != draft.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                authenticationSection
                if draft.kind == .ssh {
                    sshSection
                    forwardsSection
                } else {
                    ftpSection
                }
                organisationSection
                if !isNew {
                    Section {
                        Button("Usuń serwer", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(isNew ? "Nowy serwer" : draft.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zapisz", action: save)
                        .disabled(!isValid)
                }
            }
            .onAppear {
                guard !loadedPassword else { return }
                loadedPassword = true
                password = store.password(for: draft) ?? ""
            }
            .onChange(of: draft.kind) { oldKind, newKind in
                if draft.port == oldKind.defaultPort {
                    draft.port = newKind.defaultPort
                }
            }
            .confirmationDialog("Usunąć ten serwer?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Usuń", role: .destructive) {
                    store.delete(draft)
                    dismiss()
                }
            }
        }
    }

    private var connectionSection: some View {
        Section("Połączenie") {
            Picker("Protokół", selection: $draft.kind) {
                ForEach(ConnectionKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            TextField("Nazwa (np. Serwer produkcyjny)", text: $draft.name)
            TextField("Adres (host, IP lub nazwa MagicDNS)", text: $draft.hostname)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Text("Port")
                Spacer()
                TextField("Port", value: $draft.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
        }
    }

    private var authenticationSection: some View {
        Section {
            TextField(draft.kind == .ssh ? "Użytkownik (np. root)" : "Użytkownik (puste = anonymous)", text: $draft.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if draft.kind == .ssh {
                Picker("Metoda", selection: $draft.authMethod) {
                    ForEach(AuthMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                if draft.authMethod.usesKey || draft.authMethod == .none {
                    Picker("Klucz", selection: $draft.keyID) {
                        Text(store.keys.isEmpty ? "Brak kluczy — dodaj w zakładce Klucze" : "Wybierz…").tag(UUID?.none)
                        ForEach(store.keys) { key in
                            Label(key.name, systemImage: key.kind.symbol).tag(UUID?.some(key.id))
                        }
                    }
                }
            }

            if draft.kind != .ssh || draft.authMethod.usesPassword || draft.authMethod == .none {
                HStack {
                    Group {
                        if showPassword {
                            TextField("Hasło", text: $password)
                        } else {
                            SecureField("Hasło", text: $password)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Uwierzytelnianie")
        } footer: {
            Text("Hasło jest przechowywane w pęku kluczy iOS. Zostaw puste, aby aplikacja pytała przy każdym połączeniu.")
        }
    }

    private var sshSection: some View {
        Section {
            Picker("Host pośredni (jump)", selection: $draft.jumpHostID) {
                Text("Brak").tag(UUID?.none)
                ForEach(jumpCandidates) { host in
                    Text(host.displayName).tag(UUID?.some(host.id))
                }
            }
            TextField("Polecenie startowe (np. tmux attach || tmux)", text: $draft.startupCommand)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Katalog startowy SFTP (domyślnie: home)", text: $draft.initialPath)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("SSH")
        } footer: {
            Text("Host pośredni (ProxyJump) pozwala dostać się do serwera w sieci prywatnej przez bastion.")
        }
    }

    private var forwardsSection: some View {
        Section {
            ForEach($draft.forwards) { $rule in
                HStack(spacing: 6) {
                    TextField("8080", value: $rule.localPort, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .frame(width: 58)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("host", text: $rule.remoteHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text(":")
                        .foregroundStyle(.secondary)
                    TextField("80", value: $rule.remotePort, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .frame(width: 58)
                }
                .font(.body.monospaced())
            }
            .onDelete { offsets in
                draft.forwards.remove(atOffsets: offsets)
            }
            Button {
                draft.forwards.append(PortForwardRule())
            } label: {
                Label("Dodaj przekierowanie", systemImage: "plus")
            }
        } header: {
            Text("Przekierowanie portów (-L)")
        } footer: {
            Text("localhost:PORT na iPhonie → HOST:PORT widziany z serwera. Aktywne podczas sesji terminala, np. do panelu WWW lub bazy danych.")
        }
    }

    private var ftpSection: some View {
        Section {
            TextField("Katalog startowy (opcjonalnie)", text: $draft.initialPath)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if draft.kind == .ftps {
                Toggle("Akceptuj certyfikat self-signed", isOn: $draft.allowInsecureTLS)
            }
        } header: {
            Text("FTP")
        } footer: {
            Text(draft.kind == .ftps
                 ? "FTPS używa szyfrowania TLS od początku połączenia (implicit, zwykle port 990)."
                 : "Zwykłe FTP przesyła hasło bez szyfrowania. Jeśli to możliwe, użyj SFTP lub FTPS.")
        }
    }

    private var organisationSection: some View {
        Section("Organizacja") {
            HStack {
                TextField("Grupa (np. Produkcja)", text: $draft.group)
                if !store.groups.isEmpty {
                    Menu {
                        ForEach(store.groups, id: \.self) { group in
                            Button(group) { draft.group = group }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(HostColor.allCases) { color in
                        Circle()
                            .fill(color.color.gradient)
                            .frame(width: 30, height: 30)
                            .overlay {
                                if draft.color == color {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                }
                            }
                            .onTapGesture { draft.color = color }
                    }
                }
                .padding(.vertical, 4)
            }
            Toggle("Ulubiony", isOn: $draft.isFavorite)
            TextField("Notatki", text: $draft.notes, axis: .vertical)
                .lineLimit(2...6)
        }
    }

    private func save() {
        draft.hostname = draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.forwards = draft.forwards.filter { (1...65_535).contains($0.localPort) && (1...65_535).contains($0.remotePort) }
        store.upsert(draft)
        store.setPassword(password.isEmpty ? nil : password, for: draft)
        Haptics.success()
        dismiss()
    }
}
