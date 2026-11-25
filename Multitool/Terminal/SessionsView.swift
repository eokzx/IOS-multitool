import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var sessions: SessionManager
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            Group {
                if let active = sessions.active {
                    TerminalScreen(session: active)
                        .id(active.id)
                } else {
                    ContentUnavailableView {
                        Label("Brak aktywnych sesji", systemImage: "apple.terminal")
                    } description: {
                        Text("Połącz się z serwerem SSH, aby otworzyć terminal. Możesz mieć wiele sesji naraz i przełączać się między nimi kartami.")
                    } actions: {
                        Button("Wybierz serwer") { showPicker = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle(sessions.active?.host.displayName ?? "Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showPicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Nowa sesja")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !sessions.sessions.isEmpty {
                    SessionTabStrip()
                }
            }
            .sheet(isPresented: $showPicker) {
                HostPickerSheet()
            }
        }
    }
}

struct SessionTabStrip: View {
    @EnvironmentObject private var sessions: SessionManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sessions.sessions) { session in
                    SessionChip(
                        session: session,
                        isActive: session.id == sessions.active?.id,
                        select: { sessions.activeID = session.id },
                        close: { sessions.close(session) }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

struct SessionChip: View {
    @ObservedObject var session: TerminalSession
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(session.host.displayName)
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .lineLimit(1)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(isActive ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemFill), in: Capsule())
        .overlay(Capsule().strokeBorder(isActive ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture(perform: select)
    }

    private var statusColor: Color {
        switch session.state {
        case .connected: return .green
        case .connecting, .idle: return .orange
        case .disconnected: return .red
        }
    }
}

struct HostPickerSheet: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var sessions: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var passwordRequest: PasswordRequest?

    private var sshHosts: [ServerHost] {
        store.hosts
            .filter { $0.kind == .ssh }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List(sshHosts) { host in
                Button {
                    connect(host)
                } label: {
                    HostRow(host: host, activeSessions: sessions.count(for: host.id))
                }
            }
            .overlay {
                if sshHosts.isEmpty {
                    ContentUnavailableView(
                        "Brak serwerów SSH",
                        systemImage: "server.rack",
                        description: Text("Dodaj serwer w zakładce Serwery.")
                    )
                }
            }
            .navigationTitle("Nowa sesja")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
            }
            .passwordPrompt($passwordRequest, store: store)
        }
    }

    private func connect(_ host: ServerHost) {
        if ConnectionHelper.needsPassword(host, store: store) {
            passwordRequest = PasswordRequest(host: host) { password in
                sessions.open(host, password: password)
                dismiss()
            }
        } else {
            sessions.open(host)
            dismiss()
        }
    }
}
