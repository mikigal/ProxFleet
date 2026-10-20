import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Status and output of one task, updated while it runs.
struct TaskLogView: View {
    let connection: ServerConnection
    let node: String
    let upid: String

    @State private var status: TaskStatus?
    @State private var lines: [TaskLogLine] = []
    @State private var error: String?

    private var title: String {
        guard let parsed = UPID(upid) else { return String(localized: "Task") }
        return TaskDescription.title(type: parsed.type, objectID: parsed.objectID)
    }

    var body: some View {
        List {
            Section {
                if let status {
                    LabeledContent("Status") {
                        if status.isRunning {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Running")
                            }
                        } else {
                            Text(status.exitStatus ?? "—")
                                .foregroundStyle(status.succeeded ? Color.green : Color.red)
                        }
                    }
                    LabeledContent("Started", value: status.startTime.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("User", value: status.user)
                    LabeledContent("Node", value: status.node)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section("Output") {
                if lines.isEmpty {
                    Text(status?.isRunning == true ? "Waiting for output…" : "No output.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(lines.map(\.text).joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                await load()
                if status?.isRunning == false { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func load() async {
        do {
            async let status = connection.send(PVE.taskStatus(node: node, upid: upid))
            async let lines = connection.send(PVE.taskLog(node: node, upid: upid, limit: 1000))
            self.status = try await status
            self.lines = try await lines
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
