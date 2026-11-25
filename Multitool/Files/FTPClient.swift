import Foundation
import Network

enum FTPError: LocalizedError {
    case notConnected
    case timeout
    case connectionClosed
    case badReply(String)
    case unexpected(code: Int, message: String)
    case loginFailed(String)
    case passiveModeFailed

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Brak połączenia z serwerem FTP."
        case .timeout: return "Przekroczono czas oczekiwania na serwer FTP."
        case .connectionClosed: return "Serwer FTP zamknął połączenie."
        case .badReply(let reply): return "Nieprawidłowa odpowiedź serwera FTP: \(reply)"
        case .unexpected(let code, let message): return "Serwer FTP (\(code)): \(message)"
        case .loginFailed(let message): return "Logowanie FTP nieudane: \(message)"
        case .passiveModeFailed: return "Nie udało się otworzyć połączenia danych (tryb pasywny)."
        }
    }
}

struct FTPReply {
    let code: Int
    let lines: [String]

    var message: String { lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
    var isPreliminary: Bool { (100..<200).contains(code) }
    var isSuccess: Bool { (200..<300).contains(code) }
}

final class ConnectionWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    init(connection: NWConnection, timeout: TimeInterval) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.finish(.success(()))
            case .failed(let error):
                self?.finish(.failure(error))
            case .cancelled:
                self?.finish(.failure(FTPError.connectionClosed))
            default:
                break
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(FTPError.timeout))
        }
    }

    private func finish(_ value: Result<Void, Error>) {
        lock.lock()
        if result != nil {
            lock.unlock()
            return
        }
        result = value
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: value)
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

enum NWIO {
    static func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    static func sendEndOfStream(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

actor FTPClient {
    private let host: String
    private let port: Int
    private let useTLS: Bool
    private let allowInsecureTLS: Bool
    private let username: String
    private let password: String

    private var control: NWConnection?
    private var buffer = Data()
    private var features: Set<String> = []
    private var epsvSupported = true
    private let queue = DispatchQueue(label: "multitool.ftp")

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(host: String, port: Int, useTLS: Bool, allowInsecureTLS: Bool, username: String, password: String) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.allowInsecureTLS = allowInsecureTLS
        self.username = username
        self.password = password
    }

    func connect() async throws {
        try await serialized { }
    }

    func homeDirectory() async throws -> String {
        try await serialized {
            let reply = try await self.expect("PWD")
            let text = reply.message
            if let first = text.firstIndex(of: "\""), let last = text.lastIndex(of: "\""), first < last {
                return String(text[text.index(after: first)..<last]).replacingOccurrences(of: "\"\"", with: "\"")
            }
            return "/"
        }
    }

    func list(_ path: String) async throws -> [RemoteFile] {
        try await serialized { try await self.listUnlocked(path) }
    }

    func download(_ path: String, to local: URL, progress: @escaping (Int64) -> Void) async throws {
        try await serialized {
            FileManager.default.createFile(atPath: local.path, contents: nil)
            let handle = try FileHandle(forWritingTo: local)
            defer { try? handle.close() }
            var total: Int64 = 0
            try await self.retrieve("RETR \(path)") { chunk in
                try handle.write(contentsOf: chunk)
                total += Int64(chunk.count)
                progress(total)
            }
        }
    }

    func upload(_ local: URL, to path: String, progress: @escaping (Int64) -> Void) async throws {
        try await serialized {
            let handle = try FileHandle(forReadingFrom: local)
            defer { try? handle.close() }
            var total: Int64 = 0
            try await self.storeData("STOR \(path)") {
                let chunk = try handle.read(upToCount: 65_536)
                if let chunk {
                    total += Int64(chunk.count)
                    progress(total)
                }
                return chunk
            }
        }
    }

    func delete(path: String, isDirectory: Bool) async throws {
        try await serialized { try await self.deleteUnlocked(path: path, isDirectory: isDirectory) }
    }

    func createDirectory(_ path: String) async throws {
        try await serialized { _ = try await self.expect("MKD \(path)") }
    }

    func rename(_ from: String, to: String) async throws {
        try await serialized {
            _ = try await self.expect("RNFR \(from)", accepted: 300...399)
            _ = try await self.expect("RNTO \(to)")
        }
    }

    func chmod(_ path: String, mode: UInt32) async throws {
        try await serialized { _ = try await self.expect("SITE CHMOD \(String(mode, radix: 8)) \(path)") }
    }

    func disconnect() async {
        if let control {
            try? await NWIO.send(control, Data("QUIT\r\n".utf8))
            control.cancel()
        }
        control = nil
        buffer = Data()
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func serialized<T>(_ operation: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        do {
            try await ensureConnected()
            return try await operation()
        } catch FTPError.connectionClosed {
            resetConnection()
            try await ensureConnected()
            return try await operation()
        }
    }

    private func ensureConnected() async throws {
        if let control, control.state == .ready { return }
        resetConnection()
        try await openControlConnection()
    }

    private func resetConnection() {
        control?.cancel()
        control = nil
        buffer = Data()
    }

    private func openControlConnection() async throws {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: try endpointPort(port), using: parameters())
        let waiter = ConnectionWaiter(connection: connection, timeout: 20)
        connection.start(queue: queue)
        try await waiter.wait()
        control = connection

        let greeting = try await readReply()
        guard greeting.code == 220 else {
            throw FTPError.unexpected(code: greeting.code, message: greeting.message)
        }

        let user = username.isEmpty ? "anonymous" : username
        var reply = try await command("USER \(user)")
        if reply.code == 331 || reply.code == 332 {
            let pass = (password.isEmpty && user == "anonymous") ? "anonymous@" : password
            reply = try await command("PASS \(pass)")
        }
        guard reply.code == 230 || reply.code == 202 else {
            throw FTPError.loginFailed(reply.message)
        }

        if useTLS {
            _ = try? await command("PBSZ 0")
            _ = try await expect("PROT P")
        }

        if let feat = try? await command("FEAT"), feat.isSuccess {
            features = Set(feat.lines.compactMap { line in
                line.trimmingCharacters(in: .whitespaces).uppercased().split(separator: " ").first.map(String.init)
            })
        }
        if features.contains("UTF8") {
            _ = try? await command("OPTS UTF8 ON")
        }
        _ = try await expect("TYPE I")
    }

    private func endpointPort(_ value: Int) throws -> NWEndpoint.Port {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: value)) else { throw FTPError.notConnected }
        return port
    }

    private func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 20
        guard useTLS else { return NWParameters(tls: nil, tcp: tcp) }
        let tls = NWProtocolTLS.Options()
        if allowInsecureTLS {
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
                complete(true)
            }, queue)
        }
        return NWParameters(tls: tls, tcp: tcp)
    }

    private func readLine() async throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                var lineData = buffer[buffer.startIndex..<newline]
                if lineData.last == 0x0D { lineData = lineData.dropLast() }
                let line = String(decoding: lineData, as: UTF8.self)
                buffer = Data(buffer[buffer.index(after: newline)...])
                return line
            }
            guard let control else { throw FTPError.notConnected }
            guard let chunk = try await NWIO.receive(control) else { throw FTPError.connectionClosed }
            buffer.append(chunk)
        }
    }

    private func readReply() async throws -> FTPReply {
        let first = try await readLine()
        guard first.count >= 3, let code = Int(first.prefix(3)) else { throw FTPError.badReply(first) }
        var lines = [first.count > 4 ? String(first.dropFirst(4)) : ""]
        let isMultiline = first.count > 3 && first[first.index(first.startIndex, offsetBy: 3)] == "-"
        if isMultiline {
            let terminator = "\(code) "
            while true {
                let line = try await readLine()
                if line.hasPrefix(terminator) || line == "\(code)" {
                    lines.append(String(line.dropFirst(4)))
                    break
                }
                lines.append(line)
            }
        }
        return FTPReply(code: code, lines: lines)
    }

    @discardableResult
    private func command(_ text: String) async throws -> FTPReply {
        guard let control else { throw FTPError.notConnected }
        try await NWIO.send(control, Data((text + "\r\n").utf8))
        return try await readReply()
    }

    @discardableResult
    private func expect(_ text: String, accepted: ClosedRange<Int> = 200...299) async throws -> FTPReply {
        let reply = try await command(text)
        guard accepted.contains(reply.code) else {
            throw FTPError.unexpected(code: reply.code, message: reply.message)
        }
        return reply
    }

    private func openPassive() async throws -> (NWConnection, ConnectionWaiter) {
        var dataPort: Int?
        if epsvSupported {
            let reply = try await command("EPSV")
            if reply.code == 229, let parsed = Self.parseEPSV(reply.message) {
                dataPort = parsed
            } else {
                epsvSupported = false
            }
        }
        if dataPort == nil {
            let reply = try await command("PASV")
            guard reply.code == 227, let parsed = Self.parsePASV(reply.message) else {
                throw FTPError.passiveModeFailed
            }
            dataPort = parsed
        }
        guard let dataPort else { throw FTPError.passiveModeFailed }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: try endpointPort(dataPort), using: parameters())
        let waiter = ConnectionWaiter(connection: connection, timeout: 20)
        connection.start(queue: queue)
        return (connection, waiter)
    }

    static func parseEPSV(_ text: String) -> Int? {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return nil }
        let digits = text[text.index(after: open)..<close].filter { $0.isNumber }
        return Int(digits)
    }

    static func parsePASV(_ text: String) -> Int? {
        var inner = Substring(text)
        if let open = text.firstIndex(of: "("), let close = text[open...].firstIndex(of: ")") {
            inner = text[text.index(after: open)..<close]
        }
        let numbers = inner.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 6 else { return nil }
        let p1 = numbers[numbers.count - 2]
        let p2 = numbers[numbers.count - 1]
        return p1 * 256 + p2
    }

    private func retrieve(_ commandText: String, sink: (Data) throws -> Void) async throws {
        let (data, waiter) = try await openPassive()
        let reply = try await command(commandText)
        guard reply.isPreliminary else {
            data.cancel()
            throw FTPError.unexpected(code: reply.code, message: reply.message)
        }
        do {
            try await waiter.wait()
            while let chunk = try await NWIO.receive(data) {
                if !chunk.isEmpty { try sink(chunk) }
            }
        } catch {
            data.cancel()
            _ = try? await readReply()
            throw error
        }
        data.cancel()
        let done = try await readReply()
        guard done.isSuccess else { throw FTPError.unexpected(code: done.code, message: done.message) }
    }

    private func storeData(_ commandText: String, source: () throws -> Data?) async throws {
        let (data, waiter) = try await openPassive()
        let reply = try await command(commandText)
        guard reply.isPreliminary else {
            data.cancel()
            throw FTPError.unexpected(code: reply.code, message: reply.message)
        }
        do {
            try await waiter.wait()
            while let chunk = try source(), !chunk.isEmpty {
                try await NWIO.send(data, chunk)
            }
            try await NWIO.sendEndOfStream(data)
        } catch {
            data.cancel()
            _ = try? await readReply()
            throw error
        }
        let done = try await readReply()
        data.cancel()
        guard done.isSuccess else { throw FTPError.unexpected(code: done.code, message: done.message) }
    }

    private func listUnlocked(_ path: String) async throws -> [RemoteFile] {
        var raw = Data()
        if features.contains("MLSD") {
            try await retrieve("MLSD \(path)") { raw.append($0) }
            return FTPListParser.parseMLSD(String(decoding: raw, as: UTF8.self), directory: path)
        }
        _ = try await expect("CWD \(path)")
        do {
            try await retrieve("LIST -a") { raw.append($0) }
        } catch FTPError.unexpected(let code, _) where code >= 500 {
            raw = Data()
            try await retrieve("LIST") { raw.append($0) }
        }
        return FTPListParser.parseLIST(String(decoding: raw, as: UTF8.self), directory: path)
    }

    private func deleteUnlocked(path: String, isDirectory: Bool) async throws {
        guard isDirectory else {
            _ = try await expect("DELE \(path)")
            return
        }
        let attempt = try await command("RMD \(path)")
        if attempt.isSuccess { return }
        let children = try await listUnlocked(path)
        for child in children {
            try await deleteUnlocked(path: child.path, isDirectory: child.isDirectory && !child.isSymlink)
        }
        _ = try await expect("RMD \(path)")
    }
}

final class FTPBackend: RemoteFileBackend {
    private let client: FTPClient

    var shell: ShellConnection? { nil }

    private init(client: FTPClient) {
        self.client = client
    }

    static func open(host: ServerHost, password: String?) async throws -> FTPBackend {
        let client = FTPClient(
            host: host.hostname,
            port: host.port,
            useTLS: host.kind == .ftps,
            allowInsecureTLS: host.allowInsecureTLS,
            username: host.username,
            password: password ?? ""
        )
        try await client.connect()
        return FTPBackend(client: client)
    }

    func homeDirectory() async throws -> String { try await client.homeDirectory() }
    func list(_ path: String) async throws -> [RemoteFile] { try await client.list(path) }

    func download(_ path: String, to local: URL, progress: @escaping (Int64) -> Void) async throws {
        try await client.download(path, to: local, progress: progress)
    }

    func upload(_ local: URL, to path: String, progress: @escaping (Int64) -> Void) async throws {
        try await client.upload(local, to: path, progress: progress)
    }

    func delete(_ file: RemoteFile) async throws {
        try await client.delete(path: file.path, isDirectory: file.isDirectory && !file.isSymlink)
    }

    func createDirectory(_ path: String) async throws { try await client.createDirectory(path) }
    func rename(_ from: String, to: String) async throws { try await client.rename(from, to: to) }
    func setPermissions(_ path: String, mode: UInt32) async throws { try await client.chmod(path, mode: mode) }
    func close() async { await client.disconnect() }
}
