import Foundation
import SwiftUI

enum ConnectionKind: String, Codable, CaseIterable, Identifiable {
    case ssh
    case ftp
    case ftps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ssh: return "SSH / SFTP"
        case .ftp: return "FTP"
        case .ftps: return "FTPS"
        }
    }

    var shortTitle: String {
        switch self {
        case .ssh: return "SSH"
        case .ftp: return "FTP"
        case .ftps: return "FTPS"
        }
    }

    var defaultPort: Int {
        switch self {
        case .ssh: return 22
        case .ftp: return 21
        case .ftps: return 990
        }
    }

    var symbol: String {
        switch self {
        case .ssh: return "terminal"
        case .ftp, .ftps: return "externaldrive.connected.to.line.below"
        }
    }
}

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case key
    case keyThenPassword
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password: return "Hasło"
        case .key: return "Klucz SSH"
        case .keyThenPassword: return "Klucz, potem hasło"
        case .none: return "Bez hasła (Tailscale SSH)"
        }
    }

    var usesKey: Bool { self == .key || self == .keyThenPassword }
    var usesPassword: Bool { self == .password || self == .keyThenPassword }
}

enum HostColor: String, Codable, CaseIterable, Identifiable {
    case blue, teal, green, yellow, orange, red, pink, purple, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: return .blue
        case .teal: return .teal
        case .green: return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red: return .red
        case .pink: return .pink
        case .purple: return .purple
        case .gray: return .gray
        }
    }
}

struct PortForwardRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var localPort = 8080
    var remoteHost = "127.0.0.1"
    var remotePort = 80

    var summary: String { "localhost:\(localPort) → \(remoteHost):\(remotePort)" }
}

struct ServerHost: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var hostname = ""
    var port = 22
    var kind: ConnectionKind = .ssh
    var username = ""
    var authMethod: AuthMethod = .password
    var keyID: UUID?
    var jumpHostID: UUID?
    var group = ""
    var color: HostColor = .blue
    var startupCommand = ""
    var initialPath = ""
    var forwards: [PortForwardRule] = []
    var allowInsecureTLS = false
    var isFavorite = false
    var notes = ""
    var tailscaleDeviceID: String?
    var createdAt = Date()
    var lastConnectedAt: Date?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case id, name, hostname, port, kind, username, authMethod, keyID, jumpHostID, group, color
        case startupCommand, initialPath, forwards, allowInsecureTLS, isFavorite, notes, tailscaleDeviceID
        case createdAt, lastConnectedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        kind = try c.decodeIfPresent(ConnectionKind.self, forKey: .kind) ?? .ssh
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? kind.defaultPort
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        authMethod = try c.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .password
        keyID = try c.decodeIfPresent(UUID.self, forKey: .keyID)
        jumpHostID = try c.decodeIfPresent(UUID.self, forKey: .jumpHostID)
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        color = try c.decodeIfPresent(HostColor.self, forKey: .color) ?? .blue
        startupCommand = try c.decodeIfPresent(String.self, forKey: .startupCommand) ?? ""
        initialPath = try c.decodeIfPresent(String.self, forKey: .initialPath) ?? ""
        forwards = try c.decodeIfPresent([PortForwardRule].self, forKey: .forwards) ?? []
        allowInsecureTLS = try c.decodeIfPresent(Bool.self, forKey: .allowInsecureTLS) ?? false
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        tailscaleDeviceID = try c.decodeIfPresent(String.self, forKey: .tailscaleDeviceID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastConnectedAt = try c.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return hostname.isEmpty ? "Nowy serwer" : hostname
    }

    var endpointDescription: String {
        let userPart = username.isEmpty ? "" : "\(username)@"
        let portPart = port == kind.defaultPort ? "" : ":\(port)"
        return userPart + hostname + portPart
    }

    var effectiveUsername: String {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "root" : trimmed
    }

    var isAnonymousFTP: Bool {
        kind != .ssh && (username.isEmpty || username.lowercased() == "anonymous")
    }

    var sshCommand: String {
        var parts = ["ssh"]
        if port != 22 { parts.append("-p \(port)") }
        parts.append(username.isEmpty ? hostname : "\(username)@\(hostname)")
        return parts.joined(separator: " ")
    }

    func matches(_ query: String) -> Bool {
        let q = query.lowercased()
        return name.lowercased().contains(q)
            || hostname.lowercased().contains(q)
            || username.lowercased().contains(q)
            || group.lowercased().contains(q)
            || notes.lowercased().contains(q)
    }
}
