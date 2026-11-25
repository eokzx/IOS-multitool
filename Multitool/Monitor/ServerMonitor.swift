import Foundation

struct ServerSnapshot {
    struct Disk: Identifiable {
        let filesystem: String
        let mount: String
        let total: UInt64
        let used: UInt64
        var id: String { mount }
        var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    struct Proc: Identifiable {
        let pid: Int
        let user: String
        let cpu: Double
        let memory: Double
        let command: String
        var id: Int { pid }
    }

    var hostname = ""
    var os = ""
    var kernel = ""
    var uptime: TimeInterval?
    var load: [Double] = []
    var cpuCount = 1
    var memTotal: UInt64 = 0
    var memAvailable: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapFree: UInt64 = 0
    var disks: [Disk] = []
    var processes: [Proc] = []
    var cpuTotals: (total: UInt64, idle: UInt64)?
    var netTotals: (rx: UInt64, tx: UInt64)?

    var memUsed: UInt64 { memTotal > memAvailable ? memTotal - memAvailable : 0 }
    var memFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
    var swapUsed: UInt64 { swapTotal > swapFree ? swapTotal - swapFree : 0 }
    var rootDisk: Disk? { disks.first { $0.mount == "/" } ?? disks.first }
}

enum MonitorParser {
    static let script = """
    export LC_ALL=C
    echo @@HOST; hostname 2>/dev/null || uname -n
    echo @@OS; if [ -r /etc/os-release ]; then . /etc/os-release; echo "$PRETTY_NAME"; else uname -s; fi
    echo @@KERNEL; uname -r
    echo @@UPTIME; cat /proc/uptime 2>/dev/null
    echo @@LOAD; cat /proc/loadavg 2>/dev/null
    echo @@CPU; head -n1 /proc/stat 2>/dev/null
    echo @@NCPU; nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null
    echo @@MEM; grep -E "^(MemTotal|MemAvailable|SwapTotal|SwapFree):" /proc/meminfo 2>/dev/null
    echo @@DISK; df -P -k 2>/dev/null
    echo @@NET; cat /proc/net/dev 2>/dev/null
    echo @@PROC; ps -eo pid,user,pcpu,pmem,comm --sort=-pcpu 2>/dev/null | head -n 16
    echo @@END
    """

    static var command: String { "sh -c " + ShellQuote.quote(script) }

    private static let ignoredFilesystems: Set<String> = [
        "tmpfs", "devtmpfs", "overlay", "udev", "none", "shm", "efivarfs", "squashfs", "cgroup", "cgroup2",
    ]

    static func parse(_ output: String) -> ServerSnapshot {
        var sections: [String: [String]] = [:]
        var current: String?
        for rawLine in output.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("@@") {
                let name = String(line.dropFirst(2))
                current = name
                sections[name] = []
                continue
            }
            if let current, !line.isEmpty {
                sections[current, default: []].append(line)
            }
        }

        var snapshot = ServerSnapshot()
        snapshot.hostname = sections["HOST"]?.first ?? ""
        snapshot.os = sections["OS"]?.first ?? ""
        snapshot.kernel = sections["KERNEL"]?.first ?? ""

        if let first = sections["UPTIME"]?.first?.split(separator: " ").first {
            snapshot.uptime = TimeInterval(first)
        }
        if let load = sections["LOAD"]?.first {
            snapshot.load = load.split(separator: " ").prefix(3).compactMap { Double($0) }
        }
        if let cpu = sections["CPU"]?.first {
            let values = cpu.split(separator: " ", omittingEmptySubsequences: true).dropFirst().compactMap { UInt64($0) }
            if values.count >= 4 {
                let total = values.prefix(8).reduce(0, +)
                let idle = values[3] + (values.count > 4 ? values[4] : 0)
                snapshot.cpuTotals = (total, idle)
            }
        }
        snapshot.cpuCount = Int(sections["NCPU"]?.first ?? "") ?? 1

        for line in sections["MEM"] ?? [] {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let value = UInt64(parts[1]) else { continue }
            let bytes = value * 1024
            switch parts[0] {
            case "MemTotal:": snapshot.memTotal = bytes
            case "MemAvailable:": snapshot.memAvailable = bytes
            case "SwapTotal:": snapshot.swapTotal = bytes
            case "SwapFree:": snapshot.swapFree = bytes
            default: break
            }
        }

        for line in (sections["DISK"] ?? []).dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 6, let total = UInt64(parts[1]), let used = UInt64(parts[2]), total > 0 else { continue }
            let filesystem = String(parts[0])
            let mount = parts[5...].joined(separator: " ")
            let systemMount = ["/snap", "/run", "/dev", "/sys", "/proc", "/boot/efi"].contains { mount.hasPrefix($0) }
            if ignoredFilesystems.contains(filesystem) || systemMount { continue }
            if snapshot.disks.contains(where: { $0.mount == mount }) { continue }
            snapshot.disks.append(ServerSnapshot.Disk(filesystem: filesystem, mount: mount, total: total * 1024, used: used * 1024))
        }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var foundInterface = false
        for line in sections["NET"] ?? [] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            if name == "lo" || name.hasPrefix("docker") || name.hasPrefix("veth") || name.hasPrefix("br-") { continue }
            let fields = line[line.index(after: colon)...].split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 9, let received = UInt64(fields[0]), let sent = UInt64(fields[8]) else { continue }
            rx += received
            tx += sent
            foundInterface = true
        }
        if foundInterface {
            snapshot.netTotals = (rx, tx)
        }

        for line in (sections["PROC"] ?? []).dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5, let pid = Int(parts[0]), let cpu = Double(parts[2]), let memory = Double(parts[3]) else { continue }
            snapshot.processes.append(ServerSnapshot.Proc(pid: pid, user: String(parts[1]), cpu: cpu, memory: memory, command: String(parts[4])))
        }
        return snapshot
    }
}

@MainActor
final class ServerMonitorModel: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case live
        case failed(String)
    }

    struct CPUSample: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
    }

    let host: ServerHost
    private let password: String?
    private weak var store: AppStore?
    private var connection: ShellConnection?
    private var previousCPU: (total: UInt64, idle: UInt64)?
    private var previousNet: (rx: UInt64, tx: UInt64, at: Date)?

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var snapshot: ServerSnapshot?
    @Published private(set) var cpuUsage: Double?
    @Published private(set) var cpuHistory: [CPUSample] = []
    @Published private(set) var netRx: Double?
    @Published private(set) var netTx: Double?
    @Published private(set) var runToken = 0
    @Published var notice: String?

    init(host: ServerHost, password: String?, store: AppStore) {
        self.host = host
        self.password = password
        self.store = store
    }

    func run() async {
        guard let store else { return }
        let token = runToken
        phase = .connecting
        previousCPU = nil
        previousNet = nil
        do {
            let conn = try await SSHConnector.connect(host, store: store, password: password)
            guard token == runToken, !Task.isCancelled else {
                await conn.close()
                return
            }
            connection = conn
            phase = .live
            while !Task.isCancelled && token == runToken {
                await refresh()
                if case .failed = phase { break }
                let delay = cpuUsage == nil ? 1.0 : max(1, store.settings.monitorInterval)
                try? await Task.sleep(for: .seconds(delay))
            }
        } catch {
            if !Task.isCancelled {
                phase = .failed(ErrorText.describe(error))
            }
        }
        if token == runToken, let conn = connection {
            connection = nil
            await conn.close()
        }
    }

    func retry() {
        runToken += 1
    }

    private func refresh() async {
        guard let connection else { return }
        do {
            let output = try await connection.run(MonitorParser.command, mergeStreams: false)
            let parsed = MonitorParser.parse(output)

            if let totals = parsed.cpuTotals {
                if let previous = previousCPU, totals.total > previous.total {
                    let totalDelta = Double(totals.total - previous.total)
                    let idleDelta = Double(totals.idle >= previous.idle ? totals.idle - previous.idle : 0)
                    let usage = max(0, min(100, (1 - idleDelta / totalDelta) * 100))
                    cpuUsage = usage
                    cpuHistory.append(CPUSample(date: Date(), value: usage))
                    if cpuHistory.count > 60 {
                        cpuHistory.removeFirst(cpuHistory.count - 60)
                    }
                }
                previousCPU = totals
            }

            if let net = parsed.netTotals {
                let now = Date()
                if let previous = previousNet, net.rx >= previous.rx, net.tx >= previous.tx {
                    let seconds = now.timeIntervalSince(previous.at)
                    if seconds > 0 {
                        netRx = Double(net.rx - previous.rx) / seconds
                        netTx = Double(net.tx - previous.tx) / seconds
                    }
                }
                previousNet = (net.rx, net.tx, now)
            }
            snapshot = parsed
        } catch {
            if !connection.isConnected {
                phase = .failed("Połączenie zostało przerwane.")
            } else {
                notice = ErrorText.describe(error)
            }
        }
    }

    func signal(_ pid: Int, force: Bool) async {
        guard let connection else { return }
        do {
            let result = try await connection.runCollecting("kill -\(force ? "KILL" : "TERM") \(pid)")
            if result.exitCode != 0 {
                notice = result.output.isEmpty ? "Nie udało się wysłać sygnału (kod \(result.exitCode)). Może potrzebujesz uprawnień root?" : result.output
            }
        } catch {
            notice = ErrorText.describe(error)
        }
        await refresh()
    }

    func execute(_ command: String) async -> (output: String, exitCode: Int) {
        guard let connection else { return ("Brak połączenia.", -1) }
        do {
            let result = try await connection.runCollecting(command)
            return (result.output, result.exitCode)
        } catch {
            return (ErrorText.describe(error), -1)
        }
    }
}
