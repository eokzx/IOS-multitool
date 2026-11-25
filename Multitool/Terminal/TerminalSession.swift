import Foundation
import UIKit
import Combine
import SwiftTerm
import Citadel
import NIOCore
import NIOSSH

enum TerminalInput {
    case data([UInt8])
    case resize(cols: Int, rows: Int)
}

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case disconnected(String?)
    }

    let id = UUID()
    let host: ServerHost
    let connectionPassword: String?
    private let initialDirectory: String?

    @Published private(set) var state: State = .idle
    @Published private(set) var remoteTitle: String?
    @Published private(set) var currentDirectory: String?
    @Published private(set) var activeForwards: [PortForwardRule] = []
    @Published var showSnippets = false

    let terminalView: TerminalView
    let keyBar: TerminalKeyBar
    private let bridge = TerminalBridge()
    private weak var store: AppStore?
    private var connection: ShellConnection?
    private var inputContinuation: AsyncStream<TerminalInput>.Continuation?
    private var runTask: Task<Void, Never>?
    private var forwarders: [LocalPortForwarder] = []
    private var cols = 80
    private var rows = 24
    private var fontSize: CGFloat = 13
    private var pinchStartSize: CGFloat = 13
    private var userRequestedDisconnect = false
    private(set) var droppedUnexpectedly = false

    init(host: ServerHost, store: AppStore, password: String?, initialDirectory: String? = nil) {
        self.host = host
        self.store = store
        self.connectionPassword = password
        self.initialDirectory = initialDirectory
        self.terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 640))
        self.keyBar = TerminalKeyBar(width: 390)

        bridge.session = self
        terminalView.terminalDelegate = bridge
        terminalView.inputAccessoryView = keyBar
        terminalView.addGestureRecognizer(UIPinchGestureRecognizer(target: bridge, action: #selector(TerminalBridge.handlePinch(_:))))
        keyBar.onKey = { [weak self] key in
            self?.handleKey(key)
        }
        applyAppearance(store.settings)
    }

    var backgroundColor: UIColor { terminalView.nativeBackgroundColor }

    func applyAppearance(_ settings: AppSettings) {
        let theme = TerminalTheme.theme(id: settings.themeID)
        fontSize = CGFloat(settings.fontSize)
        terminalView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView.nativeBackgroundColor = UIColor(hex: theme.background)
        terminalView.nativeForegroundColor = UIColor(hex: theme.foreground)
        terminalView.backgroundColor = UIColor(hex: theme.background)
        terminalView.caretColor = UIColor(hex: theme.cursor)
        terminalView.selectedTextBackgroundColor = UIColor(hex: theme.selection)
        terminalView.installColors(theme.ansi.map { hex in
            SwiftTerm.Color(
                red: UInt16((hex >> 16) & 0xFF) * 257,
                green: UInt16((hex >> 8) & 0xFF) * 257,
                blue: UInt16(hex & 0xFF) * 257
            )
        })
        terminalView.optionAsMetaKey = settings.optionAsMeta
    }

    func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchStartSize = fontSize
        case .changed:
            let proposed = (pinchStartSize * recognizer.scale * 2).rounded() / 2
            let clamped = min(28, max(7, proposed))
            if clamped != fontSize {
                fontSize = clamped
                terminalView.font = UIFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
            }
        case .ended, .cancelled:
            store?.settings.fontSize = Double(fontSize)
        default:
            break
        }
    }

    func focus() {
        Task { @MainActor in
            _ = self.terminalView.becomeFirstResponder()
        }
    }

    func connect() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.run()
            self?.runTask = nil
        }
    }

    func reconnect() {
        guard runTask == nil else { return }
        droppedUnexpectedly = false
        connect()
    }

    func disconnect() {
        userRequestedDisconnect = true
        inputContinuation?.finish()
        if let connection {
            Task { await connection.close() }
        } else if state == .connecting {
            state = .disconnected(nil)
        }
    }

    private func run() async {
        guard let store else { return }
        userRequestedDisconnect = false
        state = .connecting
        write(line: "\u{1b}[2mŁączenie z \(host.endpointDescription)…\u{1b}[0m")

        let conn: ShellConnection
        do {
            conn = try await SSHConnector.connect(host, store: store, password: connectionPassword)
        } catch {
            finish(error: error, wasConnected: false)
            return
        }
        if userRequestedDisconnect {
            await conn.close()
            state = .disconnected(nil)
            return
        }

        connection = conn
        store.markConnected(host.id)
        state = .connected
        Haptics.success()
        startForwards(using: conn.client)
        focus()

        let (stream, continuation) = AsyncStream.makeStream(of: TerminalInput.self)
        inputContinuation = continuation
        var startup: [String] = []
        if let directory = initialDirectory, !directory.isEmpty {
            startup.append("cd \(ShellQuote.quote(directory))")
        }
        if !host.startupCommand.isEmpty {
            startup.append(host.startupCommand)
        }
        for line in startup {
            continuation.yield(.data(Array((line + "\r").utf8)))
        }

        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([.ECHO: 1])
        )
        let environment = [
            SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "LANG", value: "en_US.UTF-8"),
            SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "COLORTERM", value: "truecolor"),
        ]

        do {
            try await conn.client.withPTY(request, environment: environment) { [weak self] inbound, outbound in
                let writer = Task {
                    for await input in stream {
                        switch input {
                        case .data(let bytes):
                            try? await outbound.write(ByteBuffer(bytes: bytes))
                        case .resize(let newCols, let newRows):
                            try? await outbound.changeSize(cols: newCols, rows: newRows, pixelWidth: 0, pixelHeight: 0)
                        }
                    }
                }
                defer { writer.cancel() }

                for try await output in inbound {
                    switch output {
                    case .stdout(let buffer), .stderr(let buffer):
                        await self?.receive(buffer)
                    default:
                        break
                    }
                }
            }
            finish(error: nil, wasConnected: true)
        } catch {
            finish(error: error, wasConnected: true)
        }
    }

    private func receive(_ buffer: ByteBuffer) {
        let bytes = Array(buffer.readableBytesView)
        terminalView.feed(byteArray: bytes[...])
    }

    private func finish(error: Error?, wasConnected: Bool) {
        inputContinuation?.finish()
        inputContinuation = nil
        stopForwards()
        if let conn = connection {
            connection = nil
            Task { await conn.close() }
        }

        if userRequestedDisconnect {
            droppedUnexpectedly = false
            write(line: "\u{1b}[2m● Rozłączono.\u{1b}[0m")
            state = .disconnected(nil)
            return
        }

        if let error {
            let message = ErrorText.describe(error)
            droppedUnexpectedly = wasConnected
            write(line: "\u{1b}[31m✖ \(message)\u{1b}[0m")
            write(line: "\u{1b}[2mNaciśnij Enter, aby połączyć ponownie.\u{1b}[0m")
            state = .disconnected(message)
            Haptics.error()
        } else {
            droppedUnexpectedly = false
            write(line: "\u{1b}[2m● Sesja zakończona. Naciśnij Enter, aby połączyć ponownie.\u{1b}[0m")
            state = .disconnected(nil)
        }
    }

    private func write(line: String) {
        terminalView.feed(text: "\r\n" + line + "\r\n")
    }

    private func startForwards(using client: SSHClient) {
        stopForwards()
        for rule in host.forwards {
            let forwarder = LocalPortForwarder(rule: rule)
            forwarders.append(forwarder)
            Task {
                do {
                    try await forwarder.start(using: client)
                    self.activeForwards.append(rule)
                    self.write(line: "\u{1b}[36m⇄ Przekierowanie aktywne: \(rule.summary)\u{1b}[0m")
                } catch {
                    self.write(line: "\u{1b}[33m⚠ Nie udało się otworzyć portu \(rule.localPort): \(ErrorText.describe(error))\u{1b}[0m")
                }
            }
        }
    }

    private func stopForwards() {
        forwarders.forEach { $0.stop() }
        forwarders.removeAll()
        activeForwards.removeAll()
    }

    func send(bytes: [UInt8]) {
        guard state == .connected else { return }
        inputContinuation?.yield(.data(bytes))
    }

    func send(text: String) {
        send(bytes: Array(text.utf8))
    }

    func userInput(_ data: ArraySlice<UInt8>) {
        var bytes = Array(data)
        if keyBar.ctrlActive {
            if bytes.count == 1 {
                bytes = [Self.controlByte(bytes[0])]
            }
            keyBar.setCtrl(false)
        }
        if keyBar.altActive {
            bytes.insert(0x1B, at: 0)
            keyBar.setAlt(false)
        }
        if case .disconnected = state {
            if bytes == [13] { reconnect() }
            return
        }
        send(bytes: bytes)
    }

    static func controlByte(_ byte: UInt8) -> UInt8 {
        switch byte {
        case 0x61...0x7A: return byte - 0x60
        case 0x40...0x5F: return byte - 0x40
        case 0x20: return 0
        case 0x3F: return 0x7F
        default: return byte
        }
    }

    private func handleKey(_ key: TerminalKeyBar.Key) {
        switch key {
        case .ctrl, .alt:
            break
        case .raw(let sequence):
            var bytes = Array(sequence.utf8)
            if keyBar.altActive {
                bytes.insert(0x1B, at: 0)
                keyBar.setAlt(false)
            }
            if keyBar.ctrlActive { keyBar.setCtrl(false) }
            send(bytes: bytes)
        case .text(let text):
            userInput(Array(text.utf8)[...])
        case .paste:
            paste()
        case .hideKeyboard:
            _ = terminalView.resignFirstResponder()
        case .snippets:
            showSnippets = true
        }
    }

    func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        send(text: normalized)
    }

    func sendControlC() {
        send(bytes: [0x03])
    }

    func clearScreen() {
        send(bytes: [0x0C])
    }

    func run(_ snippet: Snippet) {
        var command = snippet.command
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r")
        if snippet.runImmediately { command += "\r" }
        send(text: command)
        focus()
    }

    func terminalResized(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        inputContinuation?.yield(.resize(cols: cols, rows: rows))
    }

    func terminalTitleChanged(_ title: String) {
        remoteTitle = title.isEmpty ? nil : title
    }

    func directoryChanged(_ directory: String?) {
        guard let directory else {
            currentDirectory = nil
            return
        }
        if let url = URL(string: directory), url.scheme == "file" {
            currentDirectory = url.path
        } else {
            currentDirectory = directory
        }
    }

    func bell() {
        if store?.settings.hapticBell ?? true {
            Haptics.warning()
        }
    }
}

final class TerminalBridge: NSObject, TerminalViewDelegate {
    weak var session: TerminalSession?

    private func onMain(_ body: @MainActor (TerminalSession) -> Void) {
        MainActor.assumeIsolated {
            guard let session = self.session else { return }
            body(session)
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onMain { $0.terminalResized(cols: newCols, rows: newRows) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        onMain { $0.terminalTitleChanged(title) }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        onMain { $0.directoryChanged(directory) }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onMain { $0.userInput(data) }
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        MainActor.assumeIsolated {
            UIApplication.shared.open(url)
        }
    }

    func bell(source: TerminalView) {
        onMain { $0.bell() }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        MainActor.assumeIsolated {
            UIPasteboard.general.string = text
        }
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        onMain { $0.handlePinch(recognizer) }
    }
}
