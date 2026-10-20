import FleetCore
import PVEKit
import SwiftUI

/// Recent tasks of the whole server, like the task panel at the bottom of the web interface.
struct TasksView: View {
    let connection: ServerConnection
    @State private var recent: [ClusterTask] = []
    @State private var error: String?
    @State private var hasLoaded = false

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
                }
            }
        }
        .navigationTitle("Tasks")
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
