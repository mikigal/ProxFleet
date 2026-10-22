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
    @State private var canStop = false
    @State private var confirmsStop = false
    @State private var isStopping = false

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
            if let status, status.isRunning, canStop {
                Section {
                    Button(role: .destructive) {
                        confirmsStop = true
                    } label: {
                        HStack {
                            Label("Stop Task", systemImage: "stop.circle")
                            Spacer()
                            if isStopping { ProgressView() }
                        }
                    }
                    .disabled(isStopping)
                    .accessibilityIdentifier("task.stop")
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
        .alert("Stop this task?", isPresented: $confirmsStop) {
            Button("Cancel", role: .cancel) {}
            Button("Stop", role: .destructive) { Task { await stop() } }
                .accessibilityIdentifier("task.stop.confirm")
        } message: {
            Text("The task is interrupted where it is. What it already did is not undone.")
        }
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
            async let loadedStatus = connection.send(PVE.taskStatus(node: node, upid: upid))
            async let lines = connection.send(PVE.taskLog(node: node, upid: upid, limit: 1000))
            let status = try await loadedStatus
            if status.isRunning, self.status == nil {
                canStop = await connection.canStopTask(startedBy: status.user, node: node)
            }
            self.status = status
            self.lines = try await lines
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stop() async {
        isStopping = true
        defer { isStopping = false }
        do {
            try await connection.stopTask(node: node, upid: upid)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
