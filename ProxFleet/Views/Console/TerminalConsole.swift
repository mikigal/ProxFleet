import ProxmoxConsole
import ProxmoxCore
import SwiftTerm
import SwiftUI
import UIKit

/// Connects a SwiftTerm terminal view to a Proxmox `termproxy` session.
/// Owns the terminal view, so the screen survives switching tabs.
@MainActor
@Observable
final class TerminalConsoleModel: NSObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case closed(String?)
    }

    private(set) var state: State = .idle
    /// True until the server sent more than a screen clear, e.g. a container waiting for Enter.
    private(set) var isWaitingForOutput = true

    @ObservationIgnored let terminalView: TerminalView
    @ObservationIgnored private let target: ConsoleTarget
    @ObservationIgnored private let session: ProxmoxSession
    @ObservationIgnored private var connection: TerminalConnection?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var receivedBytes = 0

    init(target: ConsoleTarget, session: ProxmoxSession) {
        self.target = target
        self.session = session
        terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        super.init()
        terminalView.terminalDelegate = self
        terminalView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeBackgroundColor = .black
        terminalView.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        terminalView.backgroundColor = .black
        terminalView.accessibilityIdentifier = "terminal"
    }

    func connect() async {
        guard state != .connecting, state != .connected else { return }
        state = .connecting
        receivedBytes = 0
        isWaitingForOutput = true
        do {
            let connection = try await TerminalConnection.open(target, session: session)
            self.connection = connection
            state = .connected
            let terminal = terminalView.getTerminal()
            try? await connection.resize(columns: terminal.cols, rows: terminal.rows)
            reader = Task { [weak self] in
                do {
                    for try await chunk in connection.output {
                        self?.receive(chunk)
                    }
                    self?.state = .closed(nil)
                } catch {
                    self?.state = .closed(error.localizedDescription)
                }
            }
            _ = terminalView.becomeFirstResponder()
        } catch {
            state = .closed(error.localizedDescription)
        }
    }

    func disconnect() {
        reader?.cancel()
        connection?.close()
        connection = nil
        if state == .connected || state == .connecting { state = .idle }
    }

    func reconnect() async {
        disconnect()
        terminalView.getTerminal().resetToInitialState()
        await connect()
    }

    /// Sends Return, which makes a container's getty print its login prompt.
    func sendReturn() {
        send(Data([13]))
    }

    private func receive(_ chunk: Data) {
        receivedBytes += chunk.count
        // "ESC[H ESC[J" alone is a screen clear, not real output.
        if receivedBytes > 8 { isWaitingForOutput = false }
        terminalView.feed(byteArray: ArraySlice(chunk))
    }

    private func send(_ data: Data) {
        guard let connection else { return }
        Task { try? await connection.send(data) }
    }
}

extension TerminalConsoleModel: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        send(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let connection else { return }
        Task { try? await connection.resize(columns: newCols, rows: newRows) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
    }
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), url.scheme == "https" || url.scheme == "http" {
            UIApplication.shared.open(url)
        }
    }
}

/// The terminal plus connection state, used in the Console tab of containers.
struct TerminalConsoleView: View {
    let model: TerminalConsoleModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea(edges: .bottom)
            TerminalViewRepresentable(terminalView: model.terminalView)
                .padding(.horizontal, 4)
            switch model.state {
            case .idle, .connecting:
                ProgressView("Connecting…")
                    .tint(.white)
                    .foregroundStyle(.white)
            case .connected:
                if model.isWaitingForOutput {
                    VStack {
                        Spacer()
                        Button("Press Return to Show the Prompt") { model.sendReturn() }
                            .buttonStyle(.bordered)
                            .tint(.white)
                            .padding(.bottom, 90)
                    }
                }
            case .closed(let message):
                ContentUnavailableView {
                    Label("Console Closed", systemImage: "terminal")
                } description: {
                    Text(message ?? String(localized: "The session ended."))
                } actions: {
                    Button("Reconnect") { Task { await model.reconnect() } }
                        .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
                .background(.black.opacity(0.85))
            }
        }
        .task { await model.connect() }
    }
}

private struct TerminalViewRepresentable: UIViewRepresentable {
    let terminalView: TerminalView

    func makeUIView(context: Context) -> TerminalView { terminalView }
    func updateUIView(_ uiView: TerminalView, context: Context) {}
}
