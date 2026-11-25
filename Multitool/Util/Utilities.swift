import Foundation
import SwiftUI
import UIKit
import Network
import Citadel

enum ErrorText {
    static func describe(_ error: Error) -> String {
        if let failed = error as? SSHClient.CommandFailed {
            return "Polecenie zakończyło się kodem \(failed.exitCode)."
        }
        if let sshError = error as? SSHClientError {
            switch sshError {
            case .allAuthenticationOptionsFailed:
                return "Uwierzytelnianie nie powiodło się. Sprawdź login, hasło lub klucz."
            case .unsupportedPasswordAuthentication:
                return "Serwer nie akceptuje logowania hasłem."
            case .unsupportedPrivateKeyAuthentication:
                return "Serwer nie akceptuje logowania kluczem."
            case .channelCreationFailed:
                return "Serwer odrzucił otwarcie kanału SSH."
            default:
                return "Błąd SSH: \(sshError)"
            }
        }
        if let nwError = error as? NWError {
            switch nwError {
            case .posix(let code):
                switch code {
                case .ECONNREFUSED: return "Połączenie odrzucone — sprawdź adres i port."
                case .ETIMEDOUT: return "Przekroczono czas połączenia."
                case .EHOSTUNREACH, .ENETUNREACH: return "Host jest nieosiągalny. Jeśli to adres Tailscale, włącz VPN Tailscale."
                case .ECONNRESET: return "Połączenie zostało zresetowane przez serwer."
                default: return nwError.localizedDescription
                }
            case .dns:
                return "Nie można odnaleźć hosta (DNS)."
            case .tls(let status):
                return "Błąd TLS (\(status)). Jeśli serwer używa certyfikatu self-signed, włącz tę opcję w ustawieniach serwera."
            @unknown default:
                return nwError.localizedDescription
            }
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }

        let raw = String(describing: error)
        let lower = raw.lowercased()
        if lower.contains("connection refused") || lower.contains("connectionrefused") {
            return "Połączenie odrzucone — sprawdź adres i port."
        }
        if lower.contains("connecttimeout") || lower.contains("timeout") || lower.contains("timed out") {
            return "Przekroczono czas połączenia."
        }
        if lower.contains("socketaddresserror") || lower.contains("unknown(host") || lower.contains("dnsaerror") || lower.contains("nodename nor servname") {
            return "Nie można odnaleźć hosta (DNS)."
        }
        if lower.contains("unreachable") {
            return "Host jest nieosiągalny."
        }
        if lower.contains("invalidhostkey") {
            return "Klucz hosta został odrzucony."
        }
        if lower.contains("auth") {
            return "Uwierzytelnianie nie powiodło się. Sprawdź login, hasło lub klucz."
        }
        if lower.contains("connectionclosed") || lower.contains("eof") || lower.contains("ioonclosedchannel") || lower.contains("alreadyclosed") {
            return "Połączenie zostało zamknięte."
        }
        return raw
    }
}

enum Fmt {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(UInt64(max(0, bytesPerSecond))) + "/s"
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .numeric, time: .shortened)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes) min" }
        return "\(minutes) min"
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

@MainActor
enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }
}

struct URLItem: Identifiable {
    let url: URL
    var id: URL { url }
}

enum ShellQuote {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
