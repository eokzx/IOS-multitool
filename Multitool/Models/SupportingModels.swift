import Foundation
import SwiftUI

enum SSHKeyKind: String, Codable, CaseIterable {
    case ed25519
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521
    case secureEnclaveP256

    var title: String {
        switch self {
        case .ed25519: return "Ed25519"
        case .ecdsaP256: return "ECDSA P-256"
        case .ecdsaP384: return "ECDSA P-384"
        case .ecdsaP521: return "ECDSA P-521"
        case .secureEnclaveP256: return "Secure Enclave (P-256)"
        }
    }

    var isHardwareBacked: Bool { self == .secureEnclaveP256 }
    var symbol: String { isHardwareBacked ? "cpu" : "key.fill" }
}

struct SSHKeyItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: SSHKeyKind
    var publicKey: String
    var fingerprint: String
    var requiresBiometry = false
    var createdAt = Date()
}

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var command: String
    var runImmediately = true

    static let defaults: [Snippet] = [
        Snippet(name: "Użycie dysku", command: "df -h"),
        Snippet(name: "Pamięć", command: "free -h"),
        Snippet(name: "Procesy (htop/top)", command: "htop || top"),
        Snippet(name: "Otwarte porty", command: "ss -tulpn"),
        Snippet(name: "Działające usługi", command: "systemctl list-units --type=service --state=running --no-pager"),
        Snippet(name: "Ostatnie logi systemu", command: "journalctl -n 100 --no-pager"),
        Snippet(name: "Kontenery Docker", command: "docker ps -a"),
        Snippet(name: "Aktualizacja (apt)", command: "sudo apt update && sudo apt upgrade", runImmediately: false),
    ]
}

struct KnownHost: Codable, Identifiable, Hashable {
    var host: String
    var port: Int
    var publicKey: String
    var addedAt = Date()

    var id: String { KnownHost.key(host: host, port: port) }
    var keyType: String { publicKey.split(separator: " ").first.map(String.init) ?? "?" }
    var fingerprint: String { SSHFingerprint.sha256(openSSHKey: publicKey) }

    static func key(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, dark, light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Systemowy"
        case .dark: return "Ciemny"
        case .light: return "Jasny"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

struct AppSettings: Codable, Equatable {
    var themeID = "multitool"
    var fontSize: Double = 13
    var appearance: AppearanceMode = .system
    var biometricLock = false
    var keepScreenAwake = true
    var hapticBell = true
    var optionAsMeta = true
    var autoReconnect = true
    var showHiddenFiles = true
    var monitorInterval: Double = 3
    var tailnet = "-"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case themeID, fontSize, appearance, biometricLock, keepScreenAwake, hapticBell
        case optionAsMeta, autoReconnect, showHiddenFiles, monitorInterval, tailnet
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        themeID = try c.decodeIfPresent(String.self, forKey: .themeID) ?? d.themeID
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? d.appearance
        biometricLock = try c.decodeIfPresent(Bool.self, forKey: .biometricLock) ?? d.biometricLock
        keepScreenAwake = try c.decodeIfPresent(Bool.self, forKey: .keepScreenAwake) ?? d.keepScreenAwake
        hapticBell = try c.decodeIfPresent(Bool.self, forKey: .hapticBell) ?? d.hapticBell
        optionAsMeta = try c.decodeIfPresent(Bool.self, forKey: .optionAsMeta) ?? d.optionAsMeta
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? d.autoReconnect
        showHiddenFiles = try c.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? d.showHiddenFiles
        monitorInterval = try c.decodeIfPresent(Double.self, forKey: .monitorInterval) ?? d.monitorInterval
        tailnet = try c.decodeIfPresent(String.self, forKey: .tailnet) ?? d.tailnet
    }
}
