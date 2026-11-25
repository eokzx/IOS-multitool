import SwiftUI
import UniformTypeIdentifiers

enum KeyGenerationKind: String, Identifiable {
    case ed25519
    case secureEnclave
    var id: String { rawValue }
}

struct KeysView: View {
    @EnvironmentObject private var store: AppStore
    @State private var generateKind: KeyGenerationKind?
    @State private var showImport = false

    var body: some View {
        NavigationStack {
            List {
                if !store.keys.isEmpty {
                    Section {
                        ForEach(store.keys) { key in
                            NavigationLink {
                                KeyDetailView(keyID: key.id)
                            } label: {
                                KeyRow(key: key, usage: store.hostsUsing(key: key).count)
                            }
                        }
                        .onDelete { offsets in
                            let toDelete = offsets.map { store.keys[$0] }
                            for key in toDelete { store.deleteKey(key) }
                        }
                    }
                }
                Section {
                    Button {
                        generateKind = .secureEnclave
                    } label: {
                        Label("Wygeneruj w Secure Enclave", systemImage: "cpu")
                    }
                    Button {
                        generateKind = .ed25519
                    } label: {
                        Label("Wygeneruj klucz Ed25519", systemImage: "key.fill")
                    }
                    Button {
                        showImport = true
                    } label: {
                        Label("Importuj klucz prywatny", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("Dodaj klucz")
                } footer: {
                    Text("Klucz z Secure Enclave powstaje w sprzętowym układzie bezpieczeństwa iPhone'a i nigdy go nie opuszcza — nie da się go skopiować ani wykraść. Klucze Ed25519 możesz eksportować i używać na innych urządzeniach.")
                }
            }
            .overlay {
                if store.keys.isEmpty {
                    VStack {
                        Spacer()
                        ContentUnavailableView(
                            "Brak kluczy SSH",
                            systemImage: "key",
                            description: Text("Logowanie kluczem jest bezpieczniejsze i wygodniejsze niż hasło.")
                        )
                        .frame(maxHeight: 260)
                        Spacer()
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("Klucze SSH")
            .sheet(item: $generateKind) { kind in
                GenerateKeyView(kind: kind)
            }
            .sheet(isPresented: $showImport) {
                ImportKeyView()
            }
        }
    }
}

struct KeyRow: View {
    let key: SSHKeyItem
    let usage: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: key.kind.symbol)
                .font(.title3)
                .foregroundStyle(key.kind.isHardwareBacked ? Color.green : Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(key.name)
                    .font(.headline)
                Text(key.kind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(key.fingerprint)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if usage > 0 {
                Text(usageText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var usageText: String {
        let lastTwo = usage % 100
        let last = usage % 10
        if usage == 1 { return "1 serwer" }
        if (2...4).contains(last) && !(12...14).contains(lastTwo) { return "\(usage) serwery" }
        return "\(usage) serwerów"
    }
}

struct GenerateKeyView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let kind: KeyGenerationKind
    @State private var name: String
    @State private var requireBiometry = false
    @State private var created: SSHKeyItem?
    @State private var error: String?

    init(kind: KeyGenerationKind) {
        self.kind = kind
        _name = State(initialValue: kind == .ed25519 ? "iPhone Ed25519" : "iPhone Secure Enclave")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let created {
                    Section {
                        Label("Klucz został wygenerowany", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                    Section {
                        Text(created.publicKey)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = created.publicKey
                            Haptics.success()
                        } label: {
                            Label("Kopiuj klucz publiczny", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: created.publicKey) {
                            Label("Udostępnij", systemImage: "square.and.arrow.up")
                        }
                    } header: {
                        Text("Klucz publiczny")
                    } footer: {
                        Text("Dodaj go do ~/.ssh/authorized_keys na serwerze lub użyj opcji „Zainstaluj na serwerze” w szczegółach klucza.")
                    }
                } else {
                    Section("Nazwa") {
                        TextField("Nazwa klucza", text: $name)
                    }
                    if kind == .secureEnclave {
                        Section {
                            Toggle("Wymagaj Face ID przy każdym użyciu", isOn: $requireBiometry)
                        } footer: {
                            Text("Klucz P-256 tworzony w Secure Enclave. Nie da się go wyeksportować — jeśli zgubisz telefon, wygeneruj nowy klucz.")
                        }
                    } else {
                        Section {
                            Label("Nowoczesny, szybki i bezpieczny algorytm obsługiwany przez OpenSSH 6.5+.", systemImage: "info.circle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error {
                        Section {
                            Text(error)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(kind == .ed25519 ? "Nowy klucz Ed25519" : "Klucz w Secure Enclave")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(created == nil ? "Anuluj" : "Gotowe") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if created == nil {
                        Button("Generuj", action: generate)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func generate() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            let generated: GeneratedKey
            if kind == .ed25519 {
                generated = SSHKeyTools.generateEd25519(name: trimmed)
            } else {
                generated = try SSHKeyTools.generateSecureEnclave(name: trimmed, requireBiometry: requireBiometry)
            }
            store.addKey(generated.item, secret: generated.secret)
            created = generated.item
            Haptics.success()
        } catch {
            self.error = ErrorText.describe(error)
        }
    }
}

struct ImportKeyView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private static let defaultName = "Zaimportowany klucz"
    @State private var name = ImportKeyView.defaultName
    @State private var text = ""
    @State private var showFileImporter = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Nazwa") {
                    TextField("Nazwa klucza", text: $name)
                }
                Section {
                    TextEditor(text: $text)
                        .font(.caption.monospaced())
                        .frame(minHeight: 180)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        if let pasted = UIPasteboard.general.string { text = pasted }
                    } label: {
                        Label("Wklej ze schowka", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Wczytaj z pliku", systemImage: "folder")
                    }
                } header: {
                    Text("Klucz prywatny")
                } footer: {
                    Text("Obsługiwane formaty: OpenSSH (Ed25519, ECDSA) oraz PEM/PKCS#8. Klucze RSA i klucze zaszyfrowane hasłem nie są jeszcze obsługiwane.")
                }
                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import klucza")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Importuj", action: importKey)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    text = content
                    if name == ImportKeyView.defaultName {
                        name = url.lastPathComponent
                    }
                } else {
                    error = "Nie udało się odczytać pliku jako tekstu."
                }
            }
        }
    }

    private func importKey() {
        do {
            let imported = try SSHKeyTools.importKey(text: text, name: name.trimmingCharacters(in: .whitespaces))
            store.addKey(imported.item, secret: imported.secret)
            Haptics.success()
            dismiss()
        } catch {
            self.error = ErrorText.describe(error)
        }
    }
}
