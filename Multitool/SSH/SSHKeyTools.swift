import Foundation
import CryptoKit
import LocalAuthentication
import Security
import NIOSSH
import Citadel

enum SSHKeyError: LocalizedError {
    case unrecognizedFormat
    case encrypted
    case rsaUnsupported
    case unsupportedType(String)
    case corrupted
    case secureEnclaveUnavailable
    case accessControlFailed
    case notExportable
    case missingSecret

    var errorDescription: String? {
        switch self {
        case .unrecognizedFormat:
            return "Nie rozpoznano formatu klucza. Wklej klucz prywatny OpenSSH lub PEM."
        case .encrypted:
            return "Klucz jest zaszyfrowany hasłem. Zdejmij hasło (ssh-keygen -p -N \"\" -f <plik>) i zaimportuj ponownie — w aplikacji klucz i tak chroni pęk kluczy iOS."
        case .rsaUnsupported:
            return "Klucze RSA nie są jeszcze obsługiwane. Wygeneruj w aplikacji klucz Ed25519 lub Secure Enclave i zainstaluj go na serwerze."
        case .unsupportedType(let type):
            return "Nieobsługiwany typ klucza: \(type)."
        case .corrupted:
            return "Klucz jest uszkodzony lub niekompletny."
        case .secureEnclaveUnavailable:
            return "Secure Enclave jest niedostępny na tym urządzeniu (np. w symulatorze)."
        case .accessControlFailed:
            return "Nie udało się utworzyć zasad dostępu do klucza."
        case .notExportable:
            return "Klucza z Secure Enclave nie da się wyeksportować — to jego główna zaleta."
        case .missingSecret:
            return "Brak materiału klucza w pęku kluczy."
        }
    }
}

struct GeneratedKey {
    let item: SSHKeyItem
    let secret: Data
}

enum ParsedPrivateKey {
    case ed25519(Curve25519.Signing.PrivateKey)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)

    var kind: SSHKeyKind {
        switch self {
        case .ed25519: return .ed25519
        case .p256: return .ecdsaP256
        case .p384: return .ecdsaP384
        case .p521: return .ecdsaP521
        }
    }

    var secret: Data {
        switch self {
        case .ed25519(let key): return key.rawRepresentation
        case .p256(let key): return key.rawRepresentation
        case .p384(let key): return key.rawRepresentation
        case .p521(let key): return key.rawRepresentation
        }
    }

    var nioKey: NIOSSHPrivateKey {
        switch self {
        case .ed25519(let key): return NIOSSHPrivateKey(ed25519Key: key)
        case .p256(let key): return NIOSSHPrivateKey(p256Key: key)
        case .p384(let key): return NIOSSHPrivateKey(p384Key: key)
        case .p521(let key): return NIOSSHPrivateKey(p521Key: key)
        }
    }
}

struct SSHByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func read(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else { throw SSHKeyError.corrupted }
        let slice = Array(bytes[offset..<(offset + count)])
        offset += count
        return slice
    }

    mutating func readUInt32() throws -> UInt32 {
        let b = try read(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    mutating func readString() throws -> [UInt8] {
        let length = Int(try readUInt32())
        return try read(length)
    }

    mutating func readText() throws -> String {
        String(decoding: try readString(), as: UTF8.self)
    }
}

enum SSHKeyTools {
    static let defaultComment = "multitool@ios"

    static func publicKeyLine(for key: NIOSSHPrivateKey, comment: String) -> String {
        let base = String(openSSHPublicKey: key.publicKey)
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? base : base + " " + trimmed
    }

    private static func makeItem(name: String, kind: SSHKeyKind, nioKey: NIOSSHPrivateKey, requiresBiometry: Bool = false) -> SSHKeyItem {
        let comment = name.replacingOccurrences(of: " ", with: "-").lowercased() + "@multitool"
        let publicKey = publicKeyLine(for: nioKey, comment: comment)
        return SSHKeyItem(
            name: name,
            kind: kind,
            publicKey: publicKey,
            fingerprint: SSHFingerprint.sha256(openSSHKey: publicKey),
            requiresBiometry: requiresBiometry
        )
    }

    static func generateEd25519(name: String) -> GeneratedKey {
        let key = Curve25519.Signing.PrivateKey()
        let item = makeItem(name: name, kind: .ed25519, nioKey: NIOSSHPrivateKey(ed25519Key: key))
        return GeneratedKey(item: item, secret: key.rawRepresentation)
    }

    static func generateSecureEnclave(name: String, requireBiometry: Bool) throws -> GeneratedKey {
        guard SecureEnclave.isAvailable else { throw SSHKeyError.secureEnclaveUnavailable }
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        if requireBiometry { flags.insert(.userPresence) }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error) else {
            throw SSHKeyError.accessControlFailed
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        let item = makeItem(name: name, kind: .secureEnclaveP256, nioKey: NIOSSHPrivateKey(secureEnclaveP256Key: key), requiresBiometry: requireBiometry)
        return GeneratedKey(item: item, secret: key.dataRepresentation)
    }

    static func importKey(text: String, name: String) throws -> GeneratedKey {
        let parsed = try parse(text)
        let item = makeItem(name: name, kind: parsed.kind, nioKey: parsed.nioKey)
        return GeneratedKey(item: item, secret: parsed.secret)
    }

    static func parse(_ rawText: String) throws -> ParsedPrivateKey {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("BEGIN OPENSSH PRIVATE KEY") {
            guard let body = pemBody(text) else { throw SSHKeyError.corrupted }
            return try parseOpenSSH(body)
        }
        if text.contains("ENCRYPTED") || text.contains("Proc-Type: 4,ENCRYPTED") {
            throw SSHKeyError.encrypted
        }
        if text.contains("BEGIN RSA PRIVATE KEY") || text.hasPrefix("ssh-rsa") {
            throw SSHKeyError.rsaUnsupported
        }
        if text.contains("BEGIN EC PRIVATE KEY") || text.contains("BEGIN PRIVATE KEY") {
            if let key = try? P256.Signing.PrivateKey(pemRepresentation: text) { return .p256(key) }
            if let key = try? P384.Signing.PrivateKey(pemRepresentation: text) { return .p384(key) }
            if let key = try? P521.Signing.PrivateKey(pemRepresentation: text) { return .p521(key) }
            if let body = pemBody(text), let key = ed25519FromPKCS8(body) { return .ed25519(key) }
            throw SSHKeyError.unsupportedType("PKCS#8 (prawdopodobnie RSA)")
        }
        if text.hasPrefix("ssh-") || text.hasPrefix("ecdsa-") {
            throw SSHKeyError.unrecognizedFormat
        }
        throw SSHKeyError.unrecognizedFormat
    }

    private static func pemBody(_ text: String) -> Data? {
        let body = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-----") && !$0.contains(":") }
            .joined()
        return Data(base64Encoded: body)
    }

    private static func ed25519FromPKCS8(_ der: Data) -> Curve25519.Signing.PrivateKey? {
        let prefix: [UInt8] = [0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]
        let bytes = [UInt8](der)
        guard bytes.count >= prefix.count + 32, Array(bytes.prefix(prefix.count)) == prefix else { return nil }
        let raw = Data(bytes[prefix.count..<(prefix.count + 32)])
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    private static func parseOpenSSH(_ data: Data) throws -> ParsedPrivateKey {
        let magic = Array("openssh-key-v1".utf8) + [0]
        let bytes = [UInt8](data)
        guard bytes.count > magic.count, Array(bytes.prefix(magic.count)) == magic else {
            throw SSHKeyError.unrecognizedFormat
        }
        var reader = SSHByteReader(Array(bytes[magic.count...]))
        let cipher = try reader.readText()
        let kdf = try reader.readText()
        _ = try reader.readString()
        let count = try reader.readUInt32()
        guard count >= 1 else { throw SSHKeyError.corrupted }
        for _ in 0..<count { _ = try reader.readString() }
        guard cipher == "none", kdf == "none" else { throw SSHKeyError.encrypted }

        var priv = SSHByteReader(try reader.readString())
        let check1 = try priv.readUInt32()
        let check2 = try priv.readUInt32()
        guard check1 == check2 else { throw SSHKeyError.corrupted }
        let type = try priv.readText()

        switch type {
        case "ssh-ed25519":
            _ = try priv.readString()
            let secret = try priv.readString()
            guard secret.count >= 32 else { throw SSHKeyError.corrupted }
            return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(secret.prefix(32))))
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = try priv.readText()
            _ = try priv.readString()
            let scalar = try priv.readString()
            switch type {
            case "ecdsa-sha2-nistp256":
                return .p256(try P256.Signing.PrivateKey(rawRepresentation: normalize(scalar, size: 32)))
            case "ecdsa-sha2-nistp384":
                return .p384(try P384.Signing.PrivateKey(rawRepresentation: normalize(scalar, size: 48)))
            default:
                return .p521(try P521.Signing.PrivateKey(rawRepresentation: normalize(scalar, size: 66)))
            }
        case "ssh-rsa":
            throw SSHKeyError.rsaUnsupported
        default:
            throw SSHKeyError.unsupportedType(type)
        }
    }

    private static func normalize(_ bytes: [UInt8], size: Int) throws -> Data {
        var trimmed = Array(bytes.drop(while: { $0 == 0 }))
        guard trimmed.count <= size else { throw SSHKeyError.corrupted }
        if trimmed.count < size {
            trimmed = [UInt8](repeating: 0, count: size - trimmed.count) + trimmed
        }
        return Data(trimmed)
    }

    static func loadPrivateKey(item: SSHKeyItem, secret: Data) throws -> NIOSSHPrivateKey {
        switch item.kind {
        case .ed25519:
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: secret))
        case .ecdsaP256:
            return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: secret))
        case .ecdsaP384:
            return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: secret))
        case .ecdsaP521:
            return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: secret))
        case .secureEnclaveP256:
            let context = LAContext()
            context.localizedReason = "Użyj klucza SSH „\(item.name)”"
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: secret, authenticationContext: context)
            return NIOSSHPrivateKey(secureEnclaveP256Key: key)
        }
    }

    static func exportPrivateKey(item: SSHKeyItem, secret: Data) throws -> String {
        switch item.kind {
        case .ed25519:
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
            return key.makeSSHRepresentation(comment: item.name)
        case .ecdsaP256:
            return try P256.Signing.PrivateKey(rawRepresentation: secret).pemRepresentation
        case .ecdsaP384:
            return try P384.Signing.PrivateKey(rawRepresentation: secret).pemRepresentation
        case .ecdsaP521:
            return try P521.Signing.PrivateKey(rawRepresentation: secret).pemRepresentation
        case .secureEnclaveP256:
            throw SSHKeyError.notExportable
        }
    }

    static func installCommand(publicKey: String) -> String {
        let key = ShellQuote.quote(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
        let script = """
        umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && \
        (grep -qxF \(key) ~/.ssh/authorized_keys || printf '%s\\n' \(key) >> ~/.ssh/authorized_keys) && echo MULTITOOL_OK
        """
        return "sh -c " + ShellQuote.quote(script)
    }
}
