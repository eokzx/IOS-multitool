import SwiftUI
import UIKit

enum TerminalRoute: Hashable {
    case files(String?)
    case monitor
}

struct TerminalScreen: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var sessions: SessionManager
    @EnvironmentObject private var store: AppStore
    @State private var route: TerminalRoute?

    var body: some View {
        TerminalHostView(session: session)
            .background(Color(uiColor: session.backgroundColor).ignoresSafeArea())
            .overlay(alignment: .top) { connectingBanner }
            .overlay(alignment: .bottom) { disconnectedCard }
            .toolbar { toolbarContent }
            .sheet(isPresented: $session.showSnippets) {
                SnippetPicker { snippet in
                    session.run(snippet)
                }
            }
            .navigationDestination(item: $route) { route in
                destination(route)
            }
            .onAppear { session.focus() }
    }

    @ViewBuilder
    private var connectingBanner: some View {
        if session.state == .connecting {
            HStack(spacing: 8) {
                ProgressView()
                Text("Łączenie…")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var disconnectedCard: some View {
        if case .disconnected(let message) = session.state {
            VStack(alignment: .leading, spacing: 10) {
                Label(message == nil ? "Rozłączono" : "Połączenie przerwane", systemImage: "bolt.horizontal.circle")
                    .font(.headline)
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        session.reconnect()
                    } label: {
                        Label("Połącz ponownie", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        sessions.close(session)
                    } label: {
                        Text("Zamknij")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .frame(maxWidth: 520, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                session.showSnippets = true
            } label: {
                Image(systemName: "text.badge.plus")
            }
            .accessibilityLabel("Snippety")

            Button {
                route = .files(session.currentDirectory)
            } label: {
                Image(systemName: "folder")
            }
            .accessibilityLabel("Pliki SFTP")

            Menu {
                Button {
                    session.paste()
                } label: {
                    Label("Wklej", systemImage: "doc.on.clipboard")
                }
                Button {
                    session.sendControlC()
                } label: {
                    Label("Wyślij Ctrl+C", systemImage: "xmark.octagon")
                }
                Button {
                    session.clearScreen()
                } label: {
                    Label("Wyczyść ekran", systemImage: "eraser")
                }
                Button {
                    route = .monitor
                } label: {
                    Label("Monitor serwera", systemImage: "chart.xyaxis.line")
                }
                if !session.activeForwards.isEmpty {
                    Section("Przekierowania portów") {
                        ForEach(session.activeForwards) { rule in
                            Text(rule.summary)
                        }
                    }
                }
                Divider()
                Button {
                    session.reconnect()
                } label: {
                    Label("Połącz ponownie", systemImage: "arrow.clockwise")
                }
                .disabled(session.state == .connected || session.state == .connecting)
                Button {
                    session.disconnect()
                } label: {
                    Label("Rozłącz", systemImage: "bolt.slash")
                }
                .disabled(session.state != .connected)
                Button(role: .destructive) {
                    sessions.close(session)
                } label: {
                    Label("Zamknij sesję", systemImage: "xmark")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: TerminalRoute) -> some View {
        switch route {
        case .files(let path):
            FileBrowserView(host: session.host, password: session.connectionPassword, store: store, startPath: path)
        case .monitor:
            ServerMonitorView(host: session.host, password: session.connectionPassword, store: store)
        }
    }
}

struct TerminalHostView: UIViewRepresentable {
    let session: TerminalSession

    func makeUIView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.attach(session.terminalView)
        return container
    }

    func updateUIView(_ uiView: TerminalContainerView, context: Context) {
        uiView.attach(session.terminalView)
    }
}

final class TerminalContainerView: UIView {
    func attach(_ view: UIView) {
        if view.superview !== self {
            view.removeFromSuperview()
            addSubview(view)
        }
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.first?.frame = bounds
    }
}
