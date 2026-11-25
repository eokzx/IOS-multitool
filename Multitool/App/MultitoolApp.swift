import SwiftUI

@main
struct MultitoolApp: App {
    @StateObject private var store: AppStore
    @StateObject private var sessions: SessionManager
    @StateObject private var lock = AppLock()
    @StateObject private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        _sessions = StateObject(wrappedValue: SessionManager(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(sessions)
                .environmentObject(lock)
                .environmentObject(router)
                .environmentObject(HostKeyPrompter.shared)
                .preferredColorScheme(store.settings.appearance.colorScheme)
                .onAppear {
                    lock.prepare(enabled: store.settings.biometricLock)
                }
                .onOpenURL { url in
                    router.handle(url)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                store.saveNow()
                lock.didEnterBackground(enabled: store.settings.biometricLock)
                sessions.didEnterBackground()
            case .active:
                lock.didBecomeActive()
                sessions.didBecomeActive()
            default:
                break
            }
        }
    }
}
