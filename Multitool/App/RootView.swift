import SwiftUI

enum AppTab: Hashable {
    case hosts
    case terminal
    case keys
    case tailscale
    case settings
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .hosts
    @Published var quickConnect: QuickConnectDraft?

    func handle(_ url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }
        var draft = QuickConnectDraft()
        switch scheme {
        case "ftp": draft.kind = .ftp
        case "ftps": draft.kind = .ftps
        default: draft.kind = .ssh
        }
        var address = ""
        if let user = url.user, !user.isEmpty { address += user + "@" }
        address += url.host ?? ""
        if let port = url.port { address += ":\(port)" }
        draft.address = address
        tab = .hosts
        quickConnect = draft
    }
}

struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var sessions: SessionManager
    @EnvironmentObject private var lock: AppLock
    @EnvironmentObject private var prompter: HostKeyPrompter

    var body: some View {
        TabView(selection: $router.tab) {
            HostsView()
                .tabItem { Label("Serwery", systemImage: "server.rack") }
                .tag(AppTab.hosts)

            SessionsView()
                .tabItem { Label("Terminal", systemImage: "apple.terminal") }
                .badge(sessions.sessions.count)
                .tag(AppTab.terminal)

            KeysView()
                .tabItem { Label("Klucze", systemImage: "key.fill") }
                .tag(AppTab.keys)

            TailscaleView()
                .tabItem { Label("Tailscale", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(AppTab.tailscale)

            SettingsView()
                .tabItem { Label("Ustawienia", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .sheet(item: $prompter.challenge) { challenge in
            HostKeySheet(challenge: challenge)
                .interactiveDismissDisabled()
        }
        .overlay {
            if lock.isLocked {
                LockScreen()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: lock.isLocked)
    }
}

struct LockScreen: View {
    @EnvironmentObject private var lock: AppLock

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Multitool jest zablokowany")
                    .font(.title3.weight(.semibold))
                Text("Twoje serwery, hasła i klucze są chronione.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Odblokuj", systemImage: "faceid")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
            }
            .padding()
        }
    }
}
