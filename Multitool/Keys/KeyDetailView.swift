import SwiftUI

struct ExportedKey: Identifiable {
    let id = UUID()
    let name: String
    let text: String
}

struct KeyDetailView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var lock: AppLock
    @Environment(\.dismiss) private var dismiss

    let keyID: UUID
    @State private var showInstall = false
    @State private var exported: ExportedKey?
    @State private var confirmDelete = false
    @State private var showRename = false
    @State private var newName = ""
    @State private var error: String?

    var body: some View {
        if let key = store.key(id: keyID) {
            content(key)
        } else {
            ContentUnavailableView("Klucz został usunięty", systemImage: "key")
        }
    }

    private func content(_ key: SSHKeyItem) -> some View {
        List {
            Section {
                LabeledContent("Typ", value: key.kind.title)
                LabeledContent("Utworzono", value: Fmt.date(key.createdAt))
                if key.kind.isHardwareBacked {
                    Label(key.requiresBiometry ? "Sprzętowy · wymaga Face ID" : "Sprzętowy · nieeksportowalny", systemImage: "lock.shield")
                        .foregroundStyle(.green)
                }
                let usedBy = store.hostsUsing(key: key)
                if !usedBy.isEmpty {
                    LabeledContent("Używany przez", value: usedBy.map(\.displayName).joined(separator: ", "))
                }
            }

            Section("Odcisk SHA256") {
                Text(key.fingerprint)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }

            Section {
                Text(key.publicKey)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = key.publicKey
                    Haptics.success()
                } label: {
                    Label("Kopiuj klucz publiczny", systemImage: "doc.on.doc")
                }
                ShareLink(item: key.publicKey) {
                    Label("Udostępnij klucz publiczny", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Klucz publiczny")
            } footer: {
                Text("Wklej go do ~/.ssh/authorized_keys na serwerze albo użyj instalacji automatycznej poniżej.")
            }

            Section {
                Button {
                    showInstall = true
                } label: {
                    Label("Zainstaluj na serwerze (ssh-copy-id)", systemImage: "arrow.up.doc")
                }
                if !key.kind.isHardwareBacked {
                    Button {
                        Task { await exportPrivate(key) }
                    } label: {
                        Label("Eksportuj klucz prywatny", systemImage: "lock.open")
                    }
                }
                Button {
                    newName = key.name
                    showRename = true
                } label: {
                    Label("Zmień nazwę", systemImage: "pencil")
                }
            }

            Section {
                Button("Usuń klucz", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(key.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showInstall) {
            InstallKeySheet(key: key)
        }
        .sheet(item: $exported) { item in
            ExportedKeyView(exported: item)
        }
        .alert("Zmień nazwę", isPresented: $showRename) {
            TextField("Nazwa", text: $newName)
            Button("Zapisz") {
                let trimmed = newName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { store.renameKey(key, to: trimmed) }
            }
            Button("Anuluj", role: .cancel) {}
        }
        .confirmationDialog("Usunąć klucz „\(key.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Usuń", role: .destructive) {
                store.deleteKey(key)
                dismiss()
            }
        } message: {
            Text("Serwery używające tego klucza stracą przypisanie. Klucza z Secure Enclave nie da się odzyskać.")
        }
        .alert("Błąd", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func exportPrivate(_ key: SSHKeyItem) async {
        guard await lock.authenticate(reason: "Eksport klucza prywatnego „\(key.name)”") else { return }
        guard let secret = store.secret(for: key) else {
            error = SSHKeyError.missingSecret.errorDescription
            return
        }
        do {
            let text = try SSHKeyTools.exportPrivateKey(item: key, secret: secret)
            exported = ExportedKey(name: key.name, text: text)
        } catch {
            self.error = ErrorText.describe(error)
        }
    }
}

struct ExportedKeyView: View {
    let exported: ExportedKey
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Klucz prywatny daje pełny dostęp do Twoich serwerów. Nie wysyłaj go przez niezaszyfrowane kanały i nikomu go nie pokazuj.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Text(exported.text)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .navigationTitle(exported.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zamknij") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = exported.text
                        Haptics.success()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    ShareLink(item: exported.text)
                }
            }
        }
    }
}

struct InstallKeySheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let key: SSHKeyItem
    @State private var hostID: UUID?
    @State private var password = ""
    @State private var useForHost = true
    @State private var running = false
    @State private var result: String?
    @State private var success = false

    private var sshHosts: [ServerHost] {
        store.hosts.filter { $0.kind == .ssh }
    }

    private var selectedHost: ServerHost? {
        store.host(id: hostID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Serwer", selection: $hostID) {
                        Text("Wybierz…").tag(UUID?.none)
                        ForEach(sshHosts) { host in
                            Text(host.displayName).tag(UUID?.some(host.id))
                        }
                    }
                } footer: {
                    Text("Aplikacja zaloguje się obecną metodą (np. hasłem) i dopisze klucz do ~/.ssh/authorized_keys.")
                }

                if let host = selectedHost, store.password(for: host) == nil {
                    Section {
                        SecureField("Hasło do serwera", text: $password)
                    } footer: {
                        Text("Potrzebne tylko do tego jednego logowania — nie zostanie zapisane.")
                    }
                }

                Section {
                    Toggle("Loguj się tym kluczem na ten serwer", isOn: $useForHost)
                }

                if let result {
                    Section {
                        Label(result, systemImage: success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(success ? Color.green : Color.red)
                    }
                }
            }
            .navigationTitle("Instalacja klucza")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(success ? "Gotowe" : "Anuluj") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if running {
                        ProgressView()
                    } else {
                        Button("Zainstaluj") {
                            Task { await install() }
                        }
                        .disabled(selectedHost == nil || success)
                    }
                }
            }
        }
    }

    private func install() async {
        guard var host = selectedHost else { return }
        running = true
        result = nil
        defer { running = false }

        var connectHost = host
        if !password.isEmpty {
            if connectHost.authMethod == .key { connectHost.authMethod = .keyThenPassword }
            if connectHost.authMethod == .none { connectHost.authMethod = .password }
        }
        do {
            let connection = try await SSHConnector.connect(connectHost, store: store, password: password.isEmpty ? nil : password)
            let output = try await connection.run(SSHKeyTools.installCommand(publicKey: key.publicKey))
            await connection.close()
            if output.contains("MULTITOOL_OK") {
                success = true
                result = "Klucz zainstalowany w ~/.ssh/authorized_keys."
                if useForHost {
                    host.keyID = key.id
                    host.authMethod = store.password(for: host) == nil ? .key : .keyThenPassword
                    store.upsert(host)
                }
                Haptics.success()
            } else {
                success = false
                result = output.isEmpty ? "Nieznany błąd." : output
            }
        } catch {
            success = false
            result = ErrorText.describe(error)
            Haptics.error()
        }
    }
}
