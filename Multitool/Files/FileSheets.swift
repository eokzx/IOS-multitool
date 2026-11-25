import SwiftUI
import QuickLook

struct ChmodSheet: View {
    let item: RemoteFile
    let onApply: (UInt32) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: UInt32

    init(item: RemoteFile, onApply: @escaping (UInt32) -> Void) {
        self.item = item
        self.onApply = onApply
        _mode = State(initialValue: item.permissions ?? (item.isDirectory ? 0o755 : 0o644))
    }

    private struct Role: Identifiable {
        let id: String
        let title: String
        let shift: UInt32
    }

    private let roles = [
        Role(id: "owner", title: "Właściciel", shift: 6),
        Role(id: "group", title: "Grupa", shift: 3),
        Role(id: "other", title: "Pozostali", shift: 0),
    ]

    private let presets: [UInt32] = [0o644, 0o755, 0o600, 0o700, 0o664, 0o775, 0o777]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(String(mode & 0o777, radix: 8))
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                        Spacer()
                        Text(symbolic)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(item.path)
                }

                ForEach(roles) { role in
                    Section(role.title) {
                        Toggle("Odczyt (r)", isOn: bit(role.shift + 2))
                        Toggle("Zapis (w)", isOn: bit(role.shift + 1))
                        Toggle(item.isDirectory ? "Wejście (x)" : "Wykonywanie (x)", isOn: bit(role.shift))
                    }
                }

                Section("Szybki wybór") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(presets, id: \.self) { preset in
                                Button(String(preset, radix: 8)) { mode = preset }
                                    .buttonStyle(.bordered)
                                    .tint(preset == (mode & 0o777) ? Color.accentColor : Color.secondary)
                                    .font(.body.monospaced())
                            }
                        }
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Anuluj") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zastosuj") {
                        onApply(mode & 0o7777)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var symbolic: String {
        let letters: [Character] = ["r", "w", "x"]
        var result = ""
        for shift in stride(from: 8, through: 0, by: -1) {
            let isSet = mode & (1 << UInt32(shift)) != 0
            result.append(isSet ? letters[(8 - shift) % 3] : "-")
        }
        return result
    }

    private func bit(_ index: UInt32) -> Binding<Bool> {
        Binding(
            get: { mode & (1 << index) != 0 },
            set: { isOn in
                if isOn {
                    mode |= (1 << index)
                } else {
                    mode &= ~(1 << index)
                }
            }
        )
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
