import Foundation
import CryptoKit
import NIOCore
import NIOSSH

enum SSHFingerprint {
    static func normalized(_ openSSHKey: String) -> String {
        openSSHKey.split(separator: " ").prefix(2).joined(separator: " ")
    }

    static func sha256(openSSHKey: String) -> String {
        let parts = openSSHKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "?" }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    static func keyType(_ openSSHKey: String) -> String {
        openSSHKey.split(separator: " ").first.map(String.init) ?? "?"
    }
}

struct HostKeyChallenge: Identifiable {
    enum Kind {
        case unknown
        case changed(previousFingerprint: String)
    }

    let id = UUID()
    let host: String
    let port: Int
    let keyType: String
    let fingerprint: String
    let kind: Kind
    fileprivate let continuation: CheckedContinuation<Bool, Never>
}

@MainActor
final class HostKeyPrompter: ObservableObject {
    static let shared = HostKeyPrompter()

    @Published var challenge: HostKeyChallenge?
    private var queue: [HostKeyChallenge] = []

    func ask(host: String, port: Int, keyType: String, fingerprint: String, kind: HostKeyChallenge.Kind) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let challenge = HostKeyChallenge(host: host, port: port, keyType: keyType, fingerprint: fingerprint, kind: kind, continuation: continuation)
            if self.challenge == nil {
                self.challenge = challenge
            } else {
                self.queue.append(challenge)
            }
        }
    }

    func resolve(_ accepted: Bool) {
        guard let current = challenge else { return }
        current.continuation.resume(returning: accepted)
        challenge = queue.isEmpty ? nil : queue.removeFirst()
    }
}

final class HostKeyVerifier: NIOSSHClientServerAuthenticationDelegate {
    private let host: String
    private let port: Int
    private let store: AppStore

    init(host: String, port: Int, store: AppStore) {
        self.host = host
        self.port = port
        self.store = store
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        let host = self.host
        let port = self.port
        let store = self.store
        Task { @MainActor in
            let accepted = await HostKeyVerifier.evaluate(host: host, port: port, presented: presented, store: store)
            if accepted {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(MultitoolError.hostKeyRejected)
            }
        }
    }

    @MainActor
    static func evaluate(host: String, port: Int, presented: String, store: AppStore) async -> Bool {
        let normalized = SSHFingerprint.normalized(presented)
        let fingerprint = SSHFingerprint.sha256(openSSHKey: normalized)
        let keyType = SSHFingerprint.keyType(normalized)

        if let known = store.knownHost(host: host, port: port) {
            if SSHFingerprint.normalized(known.publicKey) == normalized { return true }
            let accepted = await HostKeyPrompter.shared.ask(
                host: host, port: port, keyType: keyType, fingerprint: fingerprint,
                kind: .changed(previousFingerprint: known.fingerprint)
            )
            if accepted { store.trust(host: host, port: port, publicKey: normalized) }
            return accepted
        }

        let accepted = await HostKeyPrompter.shared.ask(host: host, port: port, keyType: keyType, fingerprint: fingerprint, kind: .unknown)
        if accepted { store.trust(host: host, port: port, publicKey: normalized) }
        return accepted
    }
}
