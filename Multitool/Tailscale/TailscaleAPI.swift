import Foundation

struct TailscaleDevice: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let hostname: String
    let addresses: [String]
    let os: String
    let user: String?
    let lastSeen: Date?
    let connectedToControl: Bool?
    let tags: [String]
    let clientVersion: String?
    let updateAvailable: Bool
    let keyExpiryDisabled: Bool
    let expires: Date?

    private enum CodingKeys: String, CodingKey {
        case id, nodeId, name, hostname, addresses, os, user, lastSeen, connectedToControl
        case tags, clientVersion, updateAvailable, keyExpiryDisabled, expires
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacyID = try c.decodeIfPresent(String.self, forKey: .id)
        let nodeID = try c.decodeIfPresent(String.self, forKey: .nodeId)
        id = nodeID ?? legacyID ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        addresses = try c.decodeIfPresent([String].self, forKey: .addresses) ?? []
        os = try c.decodeIfPresent(String.self, forKey: .os) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user)
        lastSeen = try? c.decodeIfPresent(Date.self, forKey: .lastSeen)
        connectedToControl = try c.decodeIfPresent(Bool.self, forKey: .connectedToControl)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        clientVersion = try c.decodeIfPresent(String.self, forKey: .clientVersion)
        updateAvailable = try c.decodeIfPresent(Bool.self, forKey: .updateAvailable) ?? false
        keyExpiryDisabled = try c.decodeIfPresent(Bool.self, forKey: .keyExpiryDisabled) ?? false
        expires = try? c.decodeIfPresent(Date.self, forKey: .expires)
    }

    var ipv4: String? { addresses.first { $0.contains(".") } }
    var ipv6: String? { addresses.first { $0.contains(":") } }

    var magicDNSName: String {
        name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    var shortName: String {
        if let first = magicDNSName.split(separator: ".").first, !first.isEmpty { return String(first) }
        return hostname.isEmpty ? magicDNSName : hostname
    }

    var isOnline: Bool {
        if let connectedToControl { return connectedToControl }
        guard let lastSeen else { return false }
        return Date().timeIntervalSince(lastSeen) < 300
    }

    var osSymbol: String {
        switch os.lowercased() {
        case "linux": return "server.rack"
        case "macos": return "laptopcomputer"
        case "ios": return "iphone"
        case "windows": return "pc"
        case "android": return "candybarphone"
        case "freebsd", "openbsd": return "server.rack"
        default: return "network"
        }
    }

    var statusLine: String {
        var parts: [String] = []
        if !os.isEmpty { parts.append(os) }
        if isOnline {
            parts.append("online")
        } else if let lastSeen, lastSeen > Date(timeIntervalSince1970: 0) {
            parts.append("widziany " + Fmt.relative(lastSeen))
        } else {
            parts.append("offline")
        }
        if updateAvailable { parts.append("dostępna aktualizacja") }
        return parts.joined(separator: " · ")
    }
}

enum TailscaleError: LocalizedError {
    case http(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(let code, let message):
            if code == 401 || code == 403 {
                return "Tailscale odrzucił klucz API (\(code)). Sprawdź, czy klucz nie wygasł — klucze API są ważne maks. 90 dni."
            }
            return "Błąd Tailscale API (\(code)): \(message)"
        case .invalidResponse:
            return "Nieprawidłowa odpowiedź Tailscale API."
        }
    }
}

enum TailscaleAPI {
    private struct DevicesResponse: Decodable {
        let devices: [TailscaleDevice]
    }

    private struct ErrorResponse: Decodable {
        let message: String?
    }

    static func devices(apiKey: String, tailnet: String) async throws -> [TailscaleDevice] {
        let trimmed = tailnet.trimmingCharacters(in: .whitespacesAndNewlines)
        let tailnetPath = (trimmed.isEmpty ? "-" : trimmed).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "-"
        guard let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/\(tailnetPath)/devices?fields=all") else {
            throw TailscaleError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TailscaleError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message
                ?? String(data: data, encoding: .utf8)
                ?? ""
            throw TailscaleError.http(http.statusCode, message)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: value) { return date }
            return Date(timeIntervalSince1970: 0)
        }
        return try decoder.decode(DevicesResponse.self, from: data).devices
    }
}

extension ServerHost {
    static func fromTailscale(_ device: TailscaleDevice) -> ServerHost {
        var host = ServerHost()
        host.name = device.shortName
        host.hostname = device.ipv4 ?? device.magicDNSName
        host.kind = .ssh
        host.port = 22
        host.authMethod = .password
        host.group = "Tailscale"
        host.color = .teal
        host.tailscaleDeviceID = device.id
        host.notes = "MagicDNS: \(device.magicDNSName)"
        return host
    }
}
