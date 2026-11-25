import Foundation
import UIKit
import Combine

@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var activeID: UUID?

    private let store: AppStore
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var cancellables = Set<AnyCancellable>()

    init(store: AppStore) {
        self.store = store
        store.$settings
            .dropFirst()
            .sink { [weak self] settings in
                self?.apply(settings)
            }
            .store(in: &cancellables)
    }

    var active: TerminalSession? {
        sessions.first { $0.id == activeID } ?? sessions.last
    }

    func count(for hostID: UUID) -> Int {
        sessions.filter { $0.host.id == hostID }.count
    }

    @discardableResult
    func open(_ host: ServerHost, password: String? = nil, initialDirectory: String? = nil) -> TerminalSession {
        let session = TerminalSession(host: host, store: store, password: password, initialDirectory: initialDirectory)
        sessions.append(session)
        activeID = session.id
        session.connect()
        updateIdleTimer()
        return session
    }

    func close(_ session: TerminalSession) {
        session.disconnect()
        sessions.removeAll { $0.id == session.id }
        if activeID == session.id {
            activeID = sessions.last?.id
        }
        updateIdleTimer()
    }

    func closeAll() {
        sessions.forEach { $0.disconnect() }
        sessions.removeAll()
        activeID = nil
        updateIdleTimer()
    }

    private func apply(_ settings: AppSettings) {
        sessions.forEach { $0.applyAppearance(settings) }
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake && !sessions.isEmpty
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = store.settings.keepScreenAwake && !sessions.isEmpty
    }

    func didEnterBackground() {
        guard !sessions.isEmpty, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ssh-sessions") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endBackgroundTask()
            }
        }
    }

    func didBecomeActive() {
        endBackgroundTask()
        guard store.settings.autoReconnect else { return }
        for session in sessions where session.droppedUnexpectedly {
            session.reconnect()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
