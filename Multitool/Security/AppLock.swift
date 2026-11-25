import Foundation
import LocalAuthentication

@MainActor
final class AppLock: ObservableObject {
    @Published private(set) var isLocked = false
    private var isAuthenticating = false
    private var didPrepare = false

    func prepare(enabled: Bool) {
        guard !didPrepare else { return }
        didPrepare = true
        if enabled {
            isLocked = true
            Task { await unlock() }
        }
    }

    func didEnterBackground(enabled: Bool) {
        if enabled { isLocked = true }
    }

    func didBecomeActive() {
        if isLocked { Task { await unlock() } }
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        if await authenticate(reason: "Odblokuj Multitool") {
            isLocked = false
        }
    }

    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return true
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
