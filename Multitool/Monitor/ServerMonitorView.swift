import SwiftUI
import Charts

struct ServerMonitorView: View {
    @StateObject private var model: ServerMonitorModel
    @State private var showRunner = false

    init(host: ServerHost, password: String?, store: AppStore) {
        _model = StateObject(wrappedValue: ServerMonitorModel(host: host, password: password, store: store))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                switch model.phase {
                case .connecting:
                    ProgressView("Łączenie z \(model.host.displayName)…")
                        .padding(.top, 80)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Brak połączenia", systemImage: "bolt.horizontal.circle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Spróbuj ponownie") { model.retry() }
                            .buttonStyle(.borderedProminent)
                    }
                case .live:
                    if let snapshot = model.snapshot {
                        dashboard(snapshot)
                    } else {
                        ProgressView("Zbieranie danych…")
                            .padding(.top, 80)
                    }
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Monitor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showRunner = true
                } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .accessibilityLabel("Wykonaj polecenie")
                .disabled(model.phase != .live)
            }
        }
        .sheet(isPresented: $showRunner) {
            CommandRunnerView(model: model)
        }
        .task(id: model.runToken) {
            await model.run()
        }
        .alert("Informacja", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice ?? "")
        }
    }

    @ViewBuilder
    private func dashboard(_ s: ServerSnapshot) -> some View {
        MonitorCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.hostname.isEmpty ? model.host.displayName : s.hostname)
                        .font(.title3.bold())
                    if !s.os.isEmpty {
                        Text(s.os)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !s.kernel.isEmpty {
                        Text(verbatim: "Kernel \(s.kernel)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("na żywo")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                    if let uptime = s.uptime {
                        Text(verbatim: "uptime \(Fmt.duration(uptime))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        HStack(spacing: 12) {
            RingGauge(
                title: "CPU",
                value: (model.cpuUsage ?? 0) / 100,
                label: model.cpuUsage.map { String(format: "%.0f%%", $0) } ?? "…",
                tint: .blue
            )
            RingGauge(
                title: "RAM",
                value: s.memFraction,
                label: String(format: "%.0f%%", s.memFraction * 100),
                tint: .green
            )
            RingGauge(
                title: "Dysk /",
                value: s.rootDisk?.fraction ?? 0,
                label: s.rootDisk.map { String(format: "%.0f%%", $0.fraction * 100) } ?? "—",
                tint: .orange
            )
        }

        MonitorCard(title: "Procesor") {
            if model.cpuHistory.count > 1 {
                Chart(model.cpuHistory) { sample in
                    AreaMark(x: .value("Czas", sample.date), y: .value("CPU", sample.value))
                        .foregroundStyle(Color.blue.opacity(0.18))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Czas", sample.date), y: .value("CPU", sample.value))
                        .foregroundStyle(Color.blue)
                        .interpolationMethod(.catmullRom)
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .frame(height: 120)
            } else {
                Text("Zbieranie próbek…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            HStack {
                stat("Rdzenie", String(s.cpuCount))
                if s.load.count == 3 {
                    stat("Load 1 / 5 / 15", s.load.map { String(format: "%.2f", $0) }.joined(separator: " · "))
                }
            }
        }

        MonitorCard(title: "Pamięć") {
            ProgressView(value: s.memFraction)
                .tint(.green)
            HStack {
                stat("Użyta", Fmt.bytes(s.memUsed))
                stat("Całkowita", Fmt.bytes(s.memTotal))
                if s.swapTotal > 0 {
                    stat("Swap", "\(Fmt.bytes(s.swapUsed)) / \(Fmt.bytes(s.swapTotal))")
                }
            }
        }

        MonitorCard(title: "Sieć") {
            HStack {
                stat("↓ Pobieranie", model.netRx.map { Fmt.rate($0) } ?? "…")
                stat("↑ Wysyłanie", model.netTx.map { Fmt.rate($0) } ?? "…")
            }
        }

        if !s.disks.isEmpty {
            MonitorCard(title: "Dyski") {
                ForEach(s.disks) { disk in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(disk.mount)
                                .font(.subheadline.monospaced())
                            Spacer()
                            Text(verbatim: "\(Fmt.bytes(disk.used)) / \(Fmt.bytes(disk.total))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: disk.fraction)
                            .tint(disk.fraction > 0.9 ? Color.red : (disk.fraction > 0.75 ? Color.orange : Color.accentColor))
                    }
                }
            }
        }

        if !s.processes.isEmpty {
            MonitorCard(title: "Procesy (wg CPU)") {
                HStack {
                    Text("Proces")
                    Spacer()
                    Text("CPU").frame(width: 54, alignment: .trailing)
                    Text("RAM").frame(width: 50, alignment: .trailing)
                    Color.clear.frame(width: 30, height: 1)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(s.processes) { process in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(process.command)
                                .font(.subheadline.monospaced())
                                .lineLimit(1)
                            Text(verbatim: "PID \(process.pid) · \(process.user)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.1f%%", process.cpu))
                            .font(.caption.monospacedDigit())
                            .frame(width: 54, alignment: .trailing)
                        Text(String(format: "%.1f%%", process.memory))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                        Menu {
                            Button {
                                Task { await model.signal(process.pid, force: false) }
                            } label: {
                                Label("Zakończ (SIGTERM)", systemImage: "stop.circle")
                            }
                            Button(role: .destructive) {
                                Task { await model.signal(process.pid, force: true) }
                            } label: {
                                Label("Zabij (SIGKILL)", systemImage: "xmark.octagon")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .frame(width: 30, height: 30)
                        }
                    }
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MonitorCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct RingGauge: View {
    let title: String
    let value: Double
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.15), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, value)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: value)
                Text(label)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            .frame(width: 76, height: 76)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct CommandRunnerView: View {
    @ObservedObject var model: ServerMonitorModel
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""
    @State private var output = ""
    @State private var exitCode: Int?
    @State private var running = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("$")
                        .font(.body.monospaced().bold())
                        .foregroundStyle(.secondary)
                    TextField("np. systemctl status nginx", text: $command)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit(run)
                    Button(action: run) {
                        if running {
                            ProgressView()
                        } else {
                            Image(systemName: "play.fill")
                        }
                    }
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || running)
                }
                .padding()
                .background(.bar)

                ScrollView {
                    Text(output.isEmpty ? "Wynik polecenia pojawi się tutaj. Polecenie wykonuje się bez interaktywnego terminala — do programów takich jak vim użyj zakładki Terminal." : output)
                        .font(.footnote.monospaced())
                        .foregroundStyle(output.isEmpty ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }

                if let exitCode {
                    HStack {
                        Image(systemName: exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(exitCode == 0 ? Color.green : Color.red)
                        Text(verbatim: "Kod wyjścia: \(exitCode)")
                            .font(.caption.monospaced())
                        Spacer()
                        Button {
                            UIPasteboard.general.string = output
                        } label: {
                            Label("Kopiuj", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
            }
            .navigationTitle(model.host.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zamknij") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func run() {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !running else { return }
        running = true
        Task {
            let result = await model.execute(trimmed)
            output = result.output
            exitCode = result.exitCode
            running = false
        }
    }
}
