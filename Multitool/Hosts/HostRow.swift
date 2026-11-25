import SwiftUI

struct HostRow: View {
    let host: ServerHost
    var activeSessions: Int = 0

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(host.color.color.gradient)
                Image(systemName: host.kind.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(host.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if host.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    if host.tailscaleDeviceID != nil {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if host.jumpHostID != nil {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(host.endpointDescription)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if activeSessions > 0 {
                Text(String(activeSessions))
                    .font(.caption.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.2), in: Capsule())
                    .foregroundStyle(.green)
            }
            Text(host.kind.shortTitle)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
