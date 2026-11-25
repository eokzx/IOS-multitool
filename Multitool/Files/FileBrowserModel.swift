import Foundation
import SwiftUI

enum FileEditorError: LocalizedError {
    case tooLarge
    case notText

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "Plik jest za duży do edycji w aplikacji (limit 5 MB)."
        case .notText: return "To nie wygląda na plik tekstowy (UTF-8)."
        }
    }
}

@MainActor
final class FileBrowserModel: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case ready
        case failed(String)
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case name, size, date
        var id: String { rawValue }
        var title: String {
            switch self {
            case .name: return "Nazwa"
            case .size: return "Rozmiar"
            case .date: return "Data modyfikacji"
            }
        }
    }

    struct Transfer: Identifiable {
        let id = UUID()
        let name: String
        let isUpload: Bool
        var total: Int64?
        var done: Int64 = 0
        var finished = false
        var error: String?

        var fraction: Double? {
            guard let total, total > 0 else { return nil }
            return min(1, Double(done) / Double(total))
        }
    }

    let host: ServerHost
    private let password: String?
    private let startPath: String?
    private weak var store: AppStore?
    private var backend: RemoteFileBackend?

    @Published var phase: Phase = .connecting
    @Published private(set) var path = "/"
    @Published private(set) var items: [RemoteFile] = []
    @Published private(set) var isLoading = false
    @Published var transfers: [Transfer] = []
    @Published var sort: SortMode = .name
    @Published var showHidden: Bool
    @Published var message: String?

    init(host: ServerHost, password: String?, store: AppStore, startPath: String?) {
        self.host = host
        self.password = password
        self.store = store
        self.startPath = startPath
        self.showHidden = store.settings.showHiddenFiles
    }

    var canUseShell: Bool { backend?.shell != nil }

    var visibleItems: [RemoteFile] {
        var list = showHidden ? items : items.filter { !$0.isHidden }
        let mode = sort
        list.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch mode {
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size: return (a.size ?? 0) > (b.size ?? 0)
            case .date: return (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
            }
        }
        return list
    }

    func start() async {
        guard backend == nil, let store else { return }
        phase = .connecting
        do {
            let backend: RemoteFileBackend
            switch host.kind {
            case .ssh:
                backend = try await SFTPBackend.open(host: host, store: store, password: password)
            case .ftp, .ftps:
                backend = try await FTPBackend.open(host: host, password: password ?? store.password(for: host))
            }
            self.backend = backend
            store.markConnected(host.id)
            var initial = startPath ?? host.initialPath
            if initial.isEmpty {
                initial = (try? await backend.homeDirectory()) ?? "/"
            }
            phase = .ready
            await load(initial)
            if items.isEmpty && initial != "/" && message != nil {
                message = nil
                await load("/")
            }
        } catch {
            phase = .failed(ErrorText.describe(error))
        }
    }

    func retry() async {
        await closeBackend()
        await start()
    }

    func close() {
        Task { await closeBackend() }
    }

    private func closeBackend() async {
        let current = backend
        backend = nil
        await current?.close()
    }

    func load(_ newPath: String? = nil) async {
        guard let backend else { return }
        let target = newPath ?? path
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await backend.list(target)
            items = list
            path = target
        } catch {
            message = ErrorText.describe(error)
        }
    }

    func refresh() async { await load() }

    func goUp() async { await load(RemotePath.parent(path)) }

    func delete(_ item: RemoteFile) async {
        guard let backend else { return }
        do {
            try await backend.delete(item)
            Haptics.success()
            await load()
        } catch {
            message = ErrorText.describe(error)
        }
    }

    func rename(_ item: RemoteFile, to newName: String) async {
        guard let backend else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name, !trimmed.contains("/") else { return }
        do {
            try await backend.rename(item.path, to: RemotePath.join(RemotePath.parent(item.path), trimmed))
            await load()
        } catch {
            message = ErrorText.describe(error)
        }
    }

    func makeDirectory(named name: String) async {
        guard let backend else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        do {
            try await backend.createDirectory(RemotePath.join(path, trimmed))
            await load()
        } catch {
            message = ErrorText.describe(error)
        }
    }

    func makeFile(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        do {
            try await saveText("", to: RemotePath.join(path, trimmed))
            await load()
        } catch {
            message = ErrorText.describe(error)
        }
    }

    func chmod(_ item: RemoteFile, mode: UInt32) async {
        guard let backend else { return }
        do {
            try await backend.setPermissions(item.path, mode: mode)
            await load()
        } catch {
            message = ErrorText.describe(error)
        }
    }

    static func downloadsDirectory(for host: ServerHost) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safeName = host.displayName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let directory = documents.appendingPathComponent("Pobrane", isDirectory: true).appendingPathComponent(safeName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func download(_ item: RemoteFile) async -> URL? {
        guard let backend else { return nil }
        let destination = Self.downloadsDirectory(for: host).appendingPathComponent(item.name)
        try? FileManager.default.removeItem(at: destination)
        let transfer = Transfer(name: item.name, isUpload: false, total: item.size.map { Int64(clamping: $0) })
        transfers.append(transfer)
        let id = transfer.id
        let throttle = ProgressThrottle()
        do {
            try await backend.download(item.path, to: destination) { @Sendable [weak self] done in
                guard throttle.shouldEmit() else { return }
                Task { @MainActor in self?.updateTransfer(id, done: done) }
            }
            finishTransfer(id, error: nil)
            return destination
        } catch {
            finishTransfer(id, error: ErrorText.describe(error))
            message = ErrorText.describe(error)
            return nil
        }
    }

    func upload(_ urls: [URL]) async {
        guard let backend else { return }
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { Int64($0) }
            let transfer = Transfer(name: url.lastPathComponent, isUpload: true, total: size)
            transfers.append(transfer)
            let id = transfer.id
            let throttle = ProgressThrottle()
            do {
                try await backend.upload(url, to: RemotePath.join(path, url.lastPathComponent)) { @Sendable [weak self] done in
                    guard throttle.shouldEmit() else { return }
                    Task { @MainActor in self?.updateTransfer(id, done: done) }
                }
                finishTransfer(id, error: nil)
            } catch {
                finishTransfer(id, error: ErrorText.describe(error))
            }
        }
        await load()
    }

    func upload(data: Data, named name: String) async {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: temporary, options: .atomic)
            await upload([temporary])
            try? FileManager.default.removeItem(at: temporary)
        } catch {
            message = ErrorText.describe(error)
        }
    }

    private func updateTransfer(_ id: UUID, done: Int64) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].done = done
    }

    private func finishTransfer(_ id: UUID, error: String?) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].finished = true
        transfers[index].error = error
        if let total = transfers[index].total, error == nil {
            transfers[index].done = total
        }
        if error == nil { Haptics.success() } else { Haptics.error() }
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.finished }
    }

    func loadText(_ item: RemoteFile) async throws -> String {
        guard let backend else { throw MultitoolError.notConnected }
        if let size = item.size, size > 5_000_000 { throw FileEditorError.tooLarge }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await backend.download(item.path, to: temporary) { _ in }
        let data = try Data(contentsOf: temporary)
        if data.contains(0) { throw FileEditorError.notText }
        guard let text = String(data: data, encoding: .utf8) else { throw FileEditorError.notText }
        return text
    }

    func saveText(_ text: String, to remotePath: String) async throws {
        guard let backend else { throw MultitoolError.notConnected }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data(text.utf8).write(to: temporary, options: .atomic)
        try await backend.upload(temporary, to: remotePath) { _ in }
    }

    func runShell(_ command: String) async -> String {
        guard let shell = backend?.shell else { return "Polecenia są dostępne tylko przez SSH." }
        do {
            let result = try await shell.runCollecting(command)
            return result.output.isEmpty ? "(brak wyjścia, kod \(result.exitCode))" : result.output
        } catch {
            return ErrorText.describe(error)
        }
    }

    func compress(_ item: RemoteFile) async {
        let parent = RemotePath.parent(item.path)
        let archive = item.name + ".tar.gz"
        let command = "cd \(ShellQuote.quote(parent)) && tar -czf \(ShellQuote.quote(archive)) -- \(ShellQuote.quote(item.name))"
        _ = await runShell(command)
        await load()
    }

    func extract(_ item: RemoteFile) async {
        let parent = RemotePath.parent(item.path)
        let file = ShellQuote.quote(item.name)
        let command: String
        switch item.fileExtension {
        case "zip": command = "cd \(ShellQuote.quote(parent)) && unzip -o \(file)"
        default: command = "cd \(ShellQuote.quote(parent)) && tar -xf \(file)"
        }
        let output = await runShell(command)
        if output.lowercased().contains("not found") || output.lowercased().contains("error") {
            message = output
        }
        await load()
    }
}
