import SwiftUI

struct PasswordRequest: Identifiable {
    let id = UUID()
    let host: ServerHost
    let completion: (String) -> Void
}

struct PasswordPromptModifier: ViewModifier {
    @Binding var request: PasswordRequest?
    let store: AppStore
    @State private var password = ""

    func body(content: Content) -> some View {
        content.alert(
            "Hasło",
            isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
            presenting: request
        ) { pending in
            SecureField("Hasło", text: $password)
            Button("Połącz") {
                let value = password
                password = ""
                pending.completion(value)
            }
            Button("Połącz i zapamiętaj") {
                let value = password
                password = ""
                store.setPassword(value, for: pending.host)
                pending.completion(value)
            }
            Button("Anuluj", role: .cancel) {
                password = ""
            }
        } message: { pending in
            Text(pending.host.endpointDescription)
        }
    }
}

extension View {
    func passwordPrompt(_ request: Binding<PasswordRequest?>, store: AppStore) -> some View {
        modifier(PasswordPromptModifier(request: request, store: store))
    }
}

struct HostKeySheet: View {
    let challenge: HostKeyChallenge
    @EnvironmentObject private var prompter: HostKeyPrompter

    private var isChanged: Bool {
        if case .changed = challenge.kind { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(systemName: isChanged ? "exclamationmark.shield.fill" : "checkmark.shield")
                            .font(.system(size: 40))
                            .foregroundStyle(isChanged ? Color.red : Color.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(isChanged ? "Klucz hosta się zmienił!" : "Nowy serwer")
                                .font(.title3.bold())
                            Text(verbatim: "\(challenge.host):\(challenge.port)")
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(isChanged
                         ? "Serwer przedstawił inny klucz niż poprzednio. To może oznaczać reinstalację serwera albo atak typu man-in-the-middle. Akceptuj tylko, jeśli wiesz, dlaczego klucz się zmienił."
                         : "Łączysz się z tym serwerem pierwszy raz. Porównaj odcisk klucza z tym na serwerze (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub), aby mieć pewność, że to właściwa maszyna.")
                        .font(.callout)

                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Typ klucza", value: challenge.keyType)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Odcisk SHA256")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(challenge.fingerprint)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        }
                        if case .changed(let previous) = challenge.kind {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Poprzedni odcisk")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(previous)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding()
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        prompter.resolve(true)
                    } label: {
                        Text(isChanged ? "Zaakceptuj nowy klucz" : "Ufam temu serwerowi")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isChanged ? Color.red : Color.accentColor)
                    .controlSize(.large)

                    Button {
                        prompter.resolve(false)
                    } label: {
                        Text("Odrzuć i rozłącz")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Weryfikacja hosta")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
    }
}

struct QuickConnectDraft: Identifiable {
    let id = UUID()
    var kind: ConnectionKind = .ssh
    var address = ""
}

struct QuickConnectView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var sessions: SessionManager
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss

    let onOpenFiles: (ServerHost, String?) -> Void

    @State private var kind: ConnectionKind
    @State private var address: String
    @State private var password = ""
    @State private var keyID: UUID?
    @State private var saveHost = false

    init(draft: QuickConnectDraft, onOpenFiles: @escaping (ServerHost, String?) -> Void) {
        self.onOpenFiles = onOpenFiles
        _kind = State(initialValue: draft.kind)
        _address = State(initialValue: draft.address)
    }

    private var parsed: (user: String, host: String, port: Int?) {
        Self.parse(address)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Protokół", selection: $kind) {
                        ForEach(ConnectionKind.allCases) { kind in
                            Text(kind.shortTitle).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("użytkownik@host:port", text: $address)
                        .font(.body.monospaced())
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Hasło (opcjonalnie)", text: $password)
                    if kind == .ssh && !store.keys.isEmpty {
                        Picker("Klucz", selection: $keyID) {
                            Text("Bez klucza").tag(UUID?.none)
                            ForEach(store.keys) { key in
                                Text(key.name).tag(UUID?.some(key.id))
                            }
                        }
                    }
                } footer: {
                    Text("Przykłady: root@192.168.1.10, admin@serwer.pl:2222, ftp.example.com")
                }

                Section {
                    Toggle("Zapisz serwer na liście", isOn: $saveHost)
                }

                Section {
                    if kind == .ssh {
                        Button {
                            connect(openFiles: false)
                        } label: {
                            Label("Otwórz terminal", systemImage: "apple.terminal")
                        }
                    }
                    Button {
                        connect(openFiles: true)
                    } label: {
                        Label(kind == .ssh ? "Przeglądaj pliki (SFTP)" : "Przeglądaj pliki", systemImage: "folder")
                    }
                }
                .disabled(parsed.host.isEmpty)
            }
            .navigationTitle("Szybkie połączenie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
            }
        }
    }

    private func connect(openFiles: Bool) {
        let target = parsed
        var host = ServerHost()
        host.kind = kind
        host.hostname = target.host
        host.port = target.port ?? kind.defaultPort
        host.username = target.user
        host.name = target.host
        if kind == .ssh {
            if let keyID {
                host.keyID = keyID
                host.authMethod = password.isEmpty ? .key : .keyThenPassword
            } else {
                host.authMethod = .password
            }
        }
        let typedPassword: String? = password.isEmpty ? nil : password
        if saveHost {
            store.upsert(host)
            if let typedPassword { store.setPassword(typedPassword, for: host) }
        }
        dismiss()
        if openFiles {
            onOpenFiles(host, typedPassword)
        } else {
            sessions.open(host, password: typedPassword)
            router.tab = .terminal
        }
    }

    static func parse(_ text: String) -> (user: String, host: String, port: Int?) {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["ssh://", "sftp://", "ftp://", "ftps://"] where rest.lowercased().hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
        }
        if rest.hasSuffix("/") { rest.removeLast() }
        var user = ""
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            let port = after.hasPrefix(":") ? Int(after.dropFirst()) : nil
            return (user, host, port)
        }
        var port: Int?
        if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            port = Int(rest[rest.index(after: colon)...])
            rest = String(rest[..<colon])
        }
        return (user, rest, port)
    }
}
