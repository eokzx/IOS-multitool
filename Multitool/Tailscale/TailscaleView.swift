import SwiftUI

struct TailscaleView: View {
    @EnvironmentObject private var store: AppStore
    @State private var apiKeyInput = ""
    @State private var hasKey = Keychain.string(for: Keychain.Account.tailscaleAPIKey) != nil
    @State private var devices: [TailscaleDevice] = []
    @State private var loading = false
    @State private var error: String?
    @State private var editorHost: ServerHost?
    @State private var showOffline = true

    private var savedDeviceIDs: Set<String> {
        Set(store.hosts.compactMap(\.tailscaleDeviceID))
    }

    private var sortedDevices: [TailscaleDevice] {
        devices
            .filter { showOffline || $0.isOnline }
            .sorted { a, b in
                if a.isOnline != b.isOnline { return a.isOnline }
                return a.shortName.localizedCaseInsensitiveCompare(b.shortName) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            List {
                if hasKey {
                    connectedContent
                } else {
                    setupSection
                }
                Section {
                    Label("Aplikacja pobiera listę urządzeń przez API Tailscale. Do łączenia się z adresami 100.x.y.z i nazwami MagicDNS aplikacja Tailscale musi być włączona (VPN aktywny) na tym iPhonie.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Label("Na serwerach z Tailscale SSH wybierz metodę „Bez hasła (Tailscale SSH)” — uwierzytelnia Cię sam tailnet.", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link(destination: URL(string: "https://tailscale.com/download/ios")!) {
                        Label("Pobierz aplikację Tailscale", systemImage: "arrow.down.app")
                    }
                } header: {
                    Text("Jak to działa")
                }
            }
            .navigationTitle("Tailscale")
            .refreshable { await reload() }
            .task {
                if hasKey && devices.isEmpty { await reload() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if hasKey {
                        Menu {
                            Button {
                                Task { await reload() }
                            } label: {
                                Label("Odśwież", systemImage: "arrow.clockwise")
                            }
                            Toggle("Pokaż urządzenia offline", isOn: $showOffline)
                            Divider()
                            Button(role: .destructive) {
                                Keychain.delete(Keychain.Account.tailscaleAPIKey)
                                hasKey = false
                                devices = []
                            } label: {
                                Label("Odłącz klucz API", systemImage: "key.slash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .sheet(item: $editorHost) { host in
                HostEditorView(host: host)
            }
        }
    }

    @ViewBuilder
    private var connectedContent: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.settings.tailnet == "-" ? "Twój tailnet" : store.settings.tailnet)
                        .font(.headline)
                    Text(verbatim: "\(devices.filter(\.isOnline).count) online · \(devices.count) urządzeń")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if loading { ProgressView() }
            }
        }

        if let error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }

        Section {
            ForEach(sortedDevices) { device in
                Button {
                    editorHost = existingHost(for: device) ?? ServerHost.fromTailscale(device)
                } label: {
                    TailscaleDeviceRow(device: device, isSaved: savedDeviceIDs.contains(device.id))
                }
                .contextMenu {
                    Button {
                        editorHost = existingHost(for: device) ?? ServerHost.fromTailscale(device)
                    } label: {
                        Label(savedDeviceIDs.contains(device.id) ? "Edytuj serwer" : "Dodaj jako serwer SSH", systemImage: "plus.circle")
                    }
                    if let ip = device.ipv4 {
                        Button {
                            UIPasteboard.general.string = ip
                        } label: {
                            Label("Kopiuj IPv4 (\(ip))", systemImage: "doc.on.doc")
                        }
                    }
                    Button {
                        UIPasteboard.general.string = device.magicDNSName
                    } label: {
                        Label("Kopiuj nazwę MagicDNS", systemImage: "globe")
                    }
                }
            }
        } header: {
            Text("Urządzenia")
        } footer: {
            Text("Dotknij urządzenia, aby dodać je jako serwer. Zaznaczone ✓ są już zapisane.")
        }
    }

    private var setupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Połącz z Tailscale", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Text("Wklej klucz API (access token) z panelu administracyjnego Tailscale, aby zobaczyć wszystkie urządzenia ze swojej sieci i dodawać je jednym dotknięciem.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            SecureField("tskey-api-…", text: $apiKeyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Tailnet (zostaw „-” dla domyślnego)", text: $store.settings.tailnet)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                Keychain.setString(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines), for: Keychain.Account.tailscaleAPIKey)
                apiKeyInput = ""
                hasKey = true
                Task { await reload() }
            } label: {
                Label("Zapisz i pobierz urządzenia", systemImage: "arrow.down.circle")
            }
            .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            Link(destination: URL(string: "https://login.tailscale.com/admin/settings/keys")!) {
                Label("Wygeneruj klucz API w panelu Tailscale", systemImage: "arrow.up.right.square")
            }
        } footer: {
            Text("Klucz jest przechowywany wyłącznie w pęku kluczy iOS na tym urządzeniu.")
        }
    }

    private func existingHost(for device: TailscaleDevice) -> ServerHost? {
        store.hosts.first { $0.tailscaleDeviceID == device.id }
    }

    private func reload() async {
        guard let key = Keychain.string(for: Keychain.Account.tailscaleAPIKey) else {
            hasKey = false
            return
        }
        loading = true
        defer { loading = false }
        do {
            devices = try await TailscaleAPI.devices(apiKey: key, tailnet: store.settings.tailnet)
            error = nil
        } catch {
            self.error = ErrorText.describe(error)
        }
    }
}

struct TailscaleDeviceRow: View {
    let device: TailscaleDevice
    let isSaved: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.osSymbol)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(device.isOnline ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.shortName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if isSaved {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Text(device.ipv4 ?? device.magicDNSName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(device.statusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(device.isOnline ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 9, height: 9)
        }
        .padding(.vertical, 2)
    }
}
