import FleetCore
import PVEKit
import SwiftUI

/// Recent tasks of the whole server, like the task panel at the bottom of the web interface.
struct TasksView: View {
    let connection: ServerConnection
    @State private var recent: [ClusterTask] = []
    @State private var error: String?
    @State private var hasLoaded = false
    @State private var stopping: ClusterTask?
    @State private var stopError: String?

    var body: some View {
        List {
            let running = connection.tasks.runningTasks
            if !running.isEmpty {
                Section("In Progress") {
                    ForEach(running) { task in
                        NavigationLink(value: ServerRoute.task(node: task.upid.node, upid: task.id)) {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text(task.title)
                            }
                        }
                    }
                }
            }
            Section("Recent") {
                ForEach(recent) { task in
                    NavigationLink(value: ServerRoute.task(node: task.node, upid: task.upid)) {
                        ClusterTaskRow(task: task, showsGuest: true)
                    }
                    .swipeActions {
                        if task.isRunning {
                            Button("Stop", systemImage: "stop.circle") { stopping = task }
                                .tint(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle("Tasks")
        .alert("Stop this task?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }), presenting: stopping) { task in
            Button("Cancel", role: .cancel) {}
            Button("Stop", role: .destructive) { Task { await stop(task) } }
        } message: { task in
            Text("\(TaskDescription.title(type: task.type, objectID: task.objectID)) is interrupted where it is. What it already did is not undone.")
        }
        .alert("Cannot Stop the Task", isPresented: Binding(get: { stopError != nil }, set: { if !$0 { stopError = nil } })) {
            Button("OK") {}
        } message: {
            Text(stopError ?? "")
        }
        .overlay {
            if !hasLoaded {
                ProgressView()
            } else if let error, recent.isEmpty {
                ContentUnavailableView("Cannot Load Tasks", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if recent.isEmpty {
                ContentUnavailableView("No Tasks", systemImage: "list.bullet.rectangle")
            }
        }
        .refreshable { await load() }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func load() async {
        do {
            recent = try await connection.send(PVE.clusterTasks())
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        hasLoaded = true
    }

    private func stop(_ task: ClusterTask) async {
        do {
            try await connection.stopTask(node: task.node, upid: task.upid)
            await load()
        } catch {
            stopError = error.localizedDescription
        }
    }
}

struct ClusterTaskRow: View {
    let task: ClusterTask
    let showsGuest: Bool

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(showsGuest ? TaskDescription.title(type: task.type, objectID: task.objectID) : TaskDescription.title(type: task.type, objectID: nil))
                    .font(.body)
                Text("\(task.startTime, format: .relative(presentation: .named)) · \(task.user) · \(task.node)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !task.isRunning, !task.succeeded, let status = task.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if task.isRunning {
            ProgressView()
        } else if task.succeeded {
            Image(systemName: task.status == "OK" ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(task.status == "OK" ? .green : .orange)
        } else {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
