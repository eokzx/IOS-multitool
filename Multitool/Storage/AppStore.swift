import Foundation
import Combine

struct ExportBundle: Codable {
    var app = "Multitool"
    var version = 1
    var exportedAt = Date()
    var hosts: [ServerHost]
    var snippets: [Snippet]
}

extension JSONEncoder {
    static var multitool: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var multitool: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var hosts: [ServerHost] = [] { didSet { scheduleSave() } }
    @Published var keys: [SSHKeyItem] = [] { didSet { scheduleSave() } }
    @Published var snippets: [Snippet] = [] { didSet { scheduleSave() } }
    @Published var knownHosts: [KnownHost] = [] { didSet { scheduleSave() } }
    @Published var settings = AppSettings() { didSet { scheduleSave() } }

    private var isLoading = false
    private var pendingSave: DispatchWorkItem?

    private struct Snapshot: Codable {
        var version = 1
        var hosts: [ServerHost]
        var keys: [SSHKeyItem]
        var snippets: [Snippet]
        var knownHosts: [KnownHost]
        var settings: AppSettings
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Multitool", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("store.json")
    }

    init() {
        load()
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        guard let data = try? Data(contentsOf: Self.fileURL),
              let snapshot = try? JSONDecoder.multitool.decode(Snapshot.self, from: data) else {
            snippets = Snippet.defaults
            return
        }
        hosts = snapshot.hosts
        keys = snapshot.keys
        snippets = snapshot.snippets
        knownHosts = snapshot.knownHosts
        settings = snapshot.settings
    }

    private func scheduleSave() {
        guard !isLoading else { return }
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveNow()
            }
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = Snapshot(hosts: hosts, keys: keys, snippets: snippets, knownHosts: knownHosts, settings: settings)
        do {
            let data = try JSONEncoder.multitool.encode(snapshot)
            try data.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("Multitool: nie udało się zapisać danych: \(error)")
        }
    }

    func host(id: UUID?) -> ServerHost? {
        guard let id else { return nil }
        return hosts.first { $0.id == id }
    }

    func upsert(_ host: ServerHost) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
    }

    func delete(_ host: ServerHost) {
        hosts.removeAll { $0.id == host.id }
        Keychain.delete(Keychain.Account.password(host.id))
        for index in hosts.indices where hosts[index].jumpHostID == host.id {
            hosts[index].jumpHostID = nil
        }
    }

    func duplicate(_ host: ServerHost) {
        var copy = host
        copy.id = UUID()
        copy.name = host.displayName + " (kopia)"
        copy.createdAt = Date()
        copy.lastConnectedAt = nil
        copy.isFavorite = false
        hosts.append(copy)
        if let password = password(for: host) {
            setPassword(password, for: copy)
        }
    }

    func toggleFavorite(_ host: ServerHost) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index].isFavorite.toggle()
    }

    func markConnected(_ id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].lastConnectedAt = Date()
    }

    var groups: [String] {
        Array(Set(hosts.map(\.group).filter { !$0.isEmpty })).sorted()
    }

    func password(for host: ServerHost) -> String? {
        Keychain.string(for: Keychain.Account.password(host.id))
    }

    func setPassword(_ password: String?, for host: ServerHost) {
        Keychain.setString(password, for: Keychain.Account.password(host.id))
    }

    func key(id: UUID?) -> SSHKeyItem? {
        guard let id else { return nil }
        return keys.first { $0.id == id }
    }

    func addKey(_ item: SSHKeyItem, secret: Data) {
        Keychain.set(secret, for: Keychain.Account.privateKey(item.id))
        keys.append(item)
    }

    func renameKey(_ item: SSHKeyItem, to name: String) {
        guard let index = keys.firstIndex(where: { $0.id == item.id }) else { return }
        keys[index].name = name
    }

    func deleteKey(_ item: SSHKeyItem) {
        Keychain.delete(Keychain.Account.privateKey(item.id))
        keys.removeAll { $0.id == item.id }
        for index in hosts.indices where hosts[index].keyID == item.id {
            hosts[index].keyID = nil
        }
    }

    func secret(for item: SSHKeyItem) -> Data? {
        Keychain.data(for: Keychain.Account.privateKey(item.id))
    }

    func hostsUsing(key: SSHKeyItem) -> [ServerHost] {
        hosts.filter { $0.keyID == key.id }
    }

    func knownHost(host: String, port: Int) -> KnownHost? {
        let key = KnownHost.key(host: host, port: port)
        return knownHosts.first { $0.id == key }
    }

    func trust(host: String, port: Int, publicKey: String) {
        let key = KnownHost.key(host: host, port: port)
        knownHosts.removeAll { $0.id == key }
        knownHosts.append(KnownHost(host: host, port: port, publicKey: publicKey))
    }

    func forget(_ knownHost: KnownHost) {
        knownHosts.removeAll { $0.id == knownHost.id }
    }

    func upsert(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
    }

    func exportFile() throws -> URL {
        let bundle = ExportBundle(hosts: hosts, snippets: snippets)
        let data = try JSONEncoder.multitool.encode(bundle)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Multitool-\(formatter.string(from: Date())).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    func importData(_ data: Data) throws -> Int {
        let bundle = try JSONDecoder.multitool.decode(ExportBundle.self, from: data)
        for var host in bundle.hosts {
            if key(id: host.keyID) == nil { host.keyID = nil }
            upsert(host)
        }
        for snippet in bundle.snippets {
            upsert(snippet)
        }
        return bundle.hosts.count
    }
}
