import SwiftUI
import UIKit

struct FileEditorView: View {
    @ObservedObject var model: FileBrowserModel
    let file: RemoteFile

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDiscard = false
    @State private var fontSize: CGFloat = 13

    private var hasChanges: Bool { text != original }

    var body: some View {
        Group {
            if loading {
                ProgressView("Wczytywanie…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeTextView(text: $text, fontSize: fontSize)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Zamknij") {
                    if hasChanges { confirmDiscard = true } else { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Zapisz") {
                        Task { await save() }
                    }
                    .disabled(loading || !hasChanges)
                }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(file.name)
                        .font(.headline)
                        .lineLimit(1)
                    if hasChanges {
                        Text("niezapisane zmiany")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    fontSize = max(9, fontSize - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                Button {
                    fontSize = min(24, fontSize + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                Spacer()
                Text(file.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .interactiveDismissDisabled(hasChanges)
        .confirmationDialog("Masz niezapisane zmiany", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Zapisz i zamknij") {
                Task {
                    await save()
                    if !hasChanges { dismiss() }
                }
            }
            Button("Odrzuć zmiany", role: .destructive) { dismiss() }
            Button("Anuluj", role: .cancel) {}
        }
        .alert("Błąd", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        do {
            let content = try await model.loadText(file)
            text = content
            original = content
            loading = false
        } catch {
            self.error = ErrorText.describe(error)
            loading = false
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await model.saveText(text, to: file.path)
            original = text
            Haptics.success()
        } catch {
            self.error = ErrorText.describe(error)
        }
    }
}

struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text {
            view.text = text
        }
        if view.font?.pointSize != fontSize {
            view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}
