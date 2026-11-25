import Foundation
import Citadel
import NIOCore
import NIOSSH

enum MultitoolError: LocalizedError {
    case hostKeyRejected
    case missingKey
    case missingPassword
    case authenticationFailed
    case jumpHostLoop
    case notConnected
    case notSSH

    var errorDescription: String? {
        switch self {
        case .hostKeyRejected: return "Klucz hosta został odrzucony — połączenie przerwane."
        case .missingKey: return "Ten serwer używa klucza SSH, ale żaden klucz nie jest przypisany (lub został usunięty)."
        case .missingPassword: return "Brak hasła. Zapisz je w ustawieniach serwera lub podaj przy łączeniu."
        case .authenticationFailed: return "Uwierzytelnianie nie powiodło się. Sprawdź login, hasło lub klucz."
        case .jumpHostLoop: return "Nieprawidłowa konfiguracja hosta pośredniego (pętla lub brak hosta)."
        case .notConnected: return "Brak połączenia."
        case .notSSH: return "Ta funkcja wymaga połączenia SSH."
        }
    }
}

final class CredentialAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private enum Attempt {
        case none
        case key(NIOSSHPrivateKey)
        case password(String)
    }

    private let username: String
    private var attempts: [Attempt]

    init(username: String, method: AuthMethod, key: NIOSSHPrivateKey?, password: String?) {
        self.username = username
        var list: [Attempt] = []
        let usablePassword = (password?.isEmpty == false) ? password : nil
        switch method {
        case .none:
            list.append(.none)
            if let key { list.append(.key(key)) }
            if let usablePassword { list.append(.password(usablePassword)) }
        case .key:
            if let key { list.append(.key(key)) }
            if let usablePassword { list.append(.password(usablePassword)) }
        case .password:
            if let usablePassword { list.append(.password(usablePassword)) }
        case .keyThenPassword:
            if let key { list.append(.key(key)) }
            if let usablePassword { list.append(.password(usablePassword)) }
        }
        self.attempts = list
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        while !attempts.isEmpty {
            let attempt = attempts.removeFirst()
            switch attempt {
            case .none:
                nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .none))
                return
            case .key(let key):
                guard availableMethods.contains(.publicKey) else { continue }
                nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "",
                    offer: .privateKey(NIOSSHUserAuthenticationOffer.Offer.PrivateKey(privateKey: key))
                ))
                return
            case .password(let password):
                guard availableMethods.contains(.password) else { continue }
                nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "",
                    offer: .password(NIOSSHUserAuthenticationOffer.Offer.Password(password: password))
                ))
                return
            }
        }
        nextChallengePromise.fail(MultitoolError.authenticationFailed)
    }
}

final class ShellConnection {
    let client: SSHClient
    private let parent: ShellConnection?

    init(client: SSHClient, parent: ShellConnection? = nil) {
        self.client = client
        self.parent = parent
    }

    var isConnected: Bool { client.isConnected }

    func run(_ command: String, mergeStreams: Bool = true) async throws -> String {
        let buffer = try await client.executeCommand(command, mergeStreams: mergeStreams)
        return String(buffer: buffer)
    }

    func runCollecting(_ command: String) async throws -> (output: String, exitCode: Int) {
        var output = ""
        var exitCode = 0
        do {
            let stream = try await client.executeCommandStream(command)
            for try await chunk in stream {
                switch chunk {
                case .stdout(let buffer), .stderr(let buffer):
                    output += String(buffer: buffer)
                default:
                    break
                }
            }
        } catch let failed as SSHClient.CommandFailed {
            exitCode = failed.exitCode
        }
        return (output, exitCode)
    }

    func close() async {
        try? await client.close()
        await parent?.close()
    }
}

enum SSHConnector {
    @MainActor
    static func connect(_ host: ServerHost, store: AppStore, password: String? = nil, depth: Int = 0) async throws -> ShellConnection {
        guard host.kind == .ssh else { throw MultitoolError.notSSH }
        let auth = try makeAuth(for: host, store: store, passwordOverride: password)
        let validator = SSHHostKeyValidator.custom(HostKeyVerifier(host: host.hostname, port: host.port, store: store))

        if let jumpID = host.jumpHostID {
            guard depth < 4, jumpID != host.id, let jumpHost = store.host(id: jumpID) else {
                throw MultitoolError.jumpHostLoop
            }
            let jump = try await connect(jumpHost, store: store, depth: depth + 1)
            var settings = SSHClientSettings(
                host: host.hostname,
                port: host.port,
                authenticationMethod: { auth },
                hostKeyValidator: validator
            )
            settings.connectTimeout = .seconds(20)
            do {
                let client = try await jump.client.jump(to: settings)
                return ShellConnection(client: client, parent: jump)
            } catch {
                await jump.close()
                throw error
            }
        }

        let client = try await SSHClient.connect(
            host: host.hostname,
            port: host.port,
            authenticationMethod: auth,
            hostKeyValidator: validator,
            reconnect: .never,
            connectTimeout: .seconds(20)
        )
        return ShellConnection(client: client)
    }

    @MainActor
    static func makeAuth(for host: ServerHost, store: AppStore, passwordOverride: String?) throws -> SSHAuthenticationMethod {
        var privateKey: NIOSSHPrivateKey?
        if host.authMethod.usesKey || host.authMethod == .none, let item = store.key(id: host.keyID) {
            guard let secret = store.secret(for: item) else { throw SSHKeyError.missingSecret }
            privateKey = try SSHKeyTools.loadPrivateKey(item: item, secret: secret)
        }
        if host.authMethod == .key && privateKey == nil {
            throw MultitoolError.missingKey
        }
        let password = passwordOverride ?? store.password(for: host)
        if host.authMethod == .password && (password ?? "").isEmpty {
            throw MultitoolError.missingPassword
        }
        let delegate = CredentialAuthDelegate(
            username: host.effectiveUsername,
            method: host.authMethod,
            key: privateKey,
            password: password
        )
        return .custom(delegate)
    }
}

@MainActor
enum ConnectionHelper {
    static func needsPassword(_ host: ServerHost, store: AppStore) -> Bool {
        let saved = store.password(for: host) ?? ""
        switch host.kind {
        case .ssh:
            return host.authMethod == .password && saved.isEmpty
        case .ftp, .ftps:
            return !host.isAnonymousFTP && saved.isEmpty
        }
    }
}
