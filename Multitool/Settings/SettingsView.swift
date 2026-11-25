import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var lock: AppLock
    @State private var exportItem: URLItem?
    @State private var showImporter = false
    @State private var info: String?

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var biometricBinding: Binding<Bool> {
        Binding(
            get: { store.settings.biometricLock },
            set: { enabled in
                if enabled {
                    Task {
                        if await lock.authenticate(reason: "Włącz blokadę aplikacji") {
                            store.settings.biometricLock = true
                        }
                    }
                } else {
                    store.settings.biometricLock = false
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Terminal") {
                    NavigationLink {
                        ThemePickerView()
                    } label: {
                        LabeledContent("Motyw", value: TerminalTheme.theme(id: store.settings.themeID).name)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Rozmiar czcionki")
                            Spacer()
                            Text(verbatim: "\(Int(store.settings.fontSize)) pt")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $store.settings.fontSize, in: 8...24, step: 1)
                    }
                    Toggle("Option jako Meta (Alt)", isOn: $store.settings.optionAsMeta)
                    Toggle("Wibracja przy dzwonku (bell)", isOn: $store.settings.hapticBell)
                    Toggle("Nie wygaszaj ekranu podczas sesji", isOn: $store.settings.keepScreenAwake)
                    Toggle("Automatycznie łącz ponownie", isOn: $store.settings.autoReconnect)
                }

                Section("Wygląd aplikacji") {
                    Picker("Motyw aplikacji", selection: $store.settings.appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }

                Section {
                    Toggle("Blokada Face ID / kodem", isOn: biometricBinding)
                    NavigationLink {
                        KnownHostsView()
                    } label: {
                        LabeledContent("Znane hosty", value: String(store.knownHosts.count))
                    }
                } header: {
                    Text("Bezpieczeństwo")
                } footer: {
                    Text("Hasła, klucze prywatne i token Tailscale są w pęku kluczy iOS, dostępne tylko na tym urządzeniu. Klucze hostów są weryfikowane jak w OpenSSH (known_hosts).")
                }

                Section("Narzędzia") {
                    NavigationLink {
                        SnippetsView()
                    } label: {
                        Label("Snippety poleceń", systemImage: "text.badge.plus")
                    }
                    Toggle("Pokazuj ukryte pliki", isOn: $store.settings.showHiddenFiles)
                    Stepper(value: $store.settings.monitorInterval, in: 1...30, step: 1) {
                        Text(verbatim: "Odświeżanie monitora: \(Int(store.settings.monitorInterval)) s")
                    }
                }

                Section {
                    Button {
                        do {
                            exportItem = URLItem(url: try store.exportFile())
                        } catch {
                            info = ErrorText.describe(error)
                        }
                    } label: {
                        Label("Eksportuj konfigurację", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Importuj konfigurację", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("Kopia zapasowa")
                } footer: {
                    Text("Plik zawiera serwery i snippety — bez haseł i kluczy prywatnych.")
                }

                Section("Informacje") {
                    LabeledContent("Wersja", value: appVersion)
                    Link(destination: URL(string: "https://github.com/migueldeicaza/SwiftTerm")!) {
                        LabeledContent("Emulator terminala", value: "SwiftTerm")
                    }
                    Link(destination: URL(string: "https://github.com/orlandos-nl/Citadel")!) {
                        LabeledContent("SSH / SFTP", value: "Citadel + SwiftNIO SSH")
                    }
                }
            }
            .navigationTitle("Ustawienia")
            .sheet(item: $exportItem) { item in
                ActivityView(items: [item.url])
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let count = try store.importData(data)
                    info = "Zaimportowano serwery: \(count). Hasła trzeba wpisać ponownie."
                } catch {
                    info = "Nie udało się zaimportować pliku: \(ErrorText.describe(error))"
                }
            }
            .alert("Kopia zapasowa", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(info ?? "")
            }
        }
    }
}

struct ThemePickerView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List(TerminalTheme.all) { theme in
            Button {
                store.settings.themeID = theme.id
            } label: {
                HStack(spacing: 14) {
                    ThemePreview(theme: theme)
                        .frame(width: 130, height: 62)
                    Text(theme.name)
                        .foregroundStyle(.primary)
                    Spacer()
                    if theme.id == store.settings.themeID {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .navigationTitle("Motyw terminala")
    }
}

struct ThemePreview: View {
    let theme: TerminalTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text("root@srv").foregroundStyle(Color(hex: theme.ansi[2]))
                Text(":").foregroundStyle(Color(hex: theme.foreground))
                Text("~").foregroundStyle(Color(hex: theme.ansi[4]))
                Text("$ ls").foregroundStyle(Color(hex: theme.foreground))
                Text("▌").foregroundStyle(Color(hex: theme.cursor))
            }
            HStack(spacing: 3) {
                ForEach(0..<8, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: theme.ansi[index]))
                        .frame(width: 10, height: 10)
                }
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: theme.background), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}

struct KnownHostsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            ForEach(store.knownHosts) { knownHost in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(knownHost.host):\(knownHost.port)")
                        .font(.headline.monospaced())
                    Text(knownHost.keyType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(knownHost.fingerprint)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
            .onDelete { offsets in
                let items = offsets.map { store.knownHosts[$0] }
                for item in items { store.forget(item) }
            }
        }
        .overlay {
            if store.knownHosts.isEmpty {
                ContentUnavailableView(
                    "Brak znanych hostów",
                    systemImage: "checkmark.shield",
                    description: Text("Odciski kluczy serwerów pojawią się tu po pierwszym połączeniu.")
                )
            }
        }
        .navigationTitle("Znane hosty")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
    }
}
