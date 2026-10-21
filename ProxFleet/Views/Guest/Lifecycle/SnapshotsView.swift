import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Snapshots of a guest as a tree, like the web interface's Snapshots panel, with "Now" under the snapshot
/// the current state is based on.
struct SnapshotsView: View {
    let detail: GuestDetail
    @State private var showsTakeSnapshot = false
    @State private var pendingDeletion: GuestSnapshot?
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var canManage: Bool { detail.can("VM.Snapshot") && !detail.isTemplate }

    var body: some View {
        List {
            if let snapshots = detail.snapshots {
                Section {
                    ForEach(GuestSnapshot.tree(snapshots), id: \.snapshot.id) { entry in
                        if entry.snapshot.isCurrent {
                            CurrentStateRow(depth: entry.depth, isRunning: detail.powerState == .running)
                        } else {
                            NavigationLink {
                                SnapshotDetailView(detail: detail, snapshot: entry.snapshot)
                            } label: {
                                SnapshotRow(snapshot: entry.snapshot, depth: entry.depth)
                            }
                            .swipeActions {
                                if canManage {
                                    Button("Delete", role: .destructive) { pendingDeletion = entry.snapshot }
                                }
                            }
                            .accessibilityIdentifier("snapshot.\(entry.snapshot.name)")
                        }
                    }
                } footer: {
                    if snapshots.count == 1 {
                        Text("No snapshots yet. A snapshot saves the disks and settings so you can return to this state later.")
                    } else if !detail.can("VM.Snapshot") {
                        Text("Taking and deleting snapshots needs the VM.Snapshot privilege on /vms/\(String(detail.reference.vmid)).")
                    }
                }
            }
        }
        .overlay {
            if detail.snapshots == nil { ProgressView() }
        }
        .navigationTitle("Snapshots")
        .refreshable { errorMessage = await detail.loadSnapshots() }
        .task { errorMessage = await detail.loadSnapshots() }
        .disabled(isWorking)
        .toolbar {
            if canManage {
                ToolbarItem(placement: .primaryAction) {
                    Button("Take Snapshot", systemImage: "plus") { showsTakeSnapshot = true }
                        .accessibilityIdentifier("snapshot.take")
                }
            }
        }
        .sheet(isPresented: $showsTakeSnapshot) {
            NavigationStack {
                TakeSnapshotView(detail: detail)
            }
        }
        .alert("Delete \(pendingDeletion?.name ?? "")?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { snapshot in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await delete(snapshot) } }
        } message: { _ in
            Text("The current state is kept. You can no longer return to this snapshot.")
        }
        .alert("Snapshot Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func delete(_ snapshot: GuestSnapshot) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await detail.runSnapshotAction(PVE.deleteSnapshot(detail.reference, name: snapshot.name))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Indents a row by its depth in the snapshot tree, with a connector for children.
private struct TreeIndent: View {
    let depth: Int

    var body: some View {
        if depth > 0 {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, CGFloat(depth - 1) * 16)
        }
    }
}

private struct SnapshotRow: View {
    let snapshot: GuestSnapshot
    let depth: Int

    var body: some View {
        HStack(spacing: 8) {
            TreeIndent(depth: depth)
            Image(systemName: "camera.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(snapshot.name)
                        .font(.body.weight(.medium))
                    if snapshot.includesRAM {
                        Text("RAM")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                }
                if let date = snapshot.date {
                    Text(date, format: .dateTime.day().month().year().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !snapshot.description.isEmpty {
                    Text(snapshot.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct CurrentStateRow: View {
    let depth: Int
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 8) {
            TreeIndent(depth: depth)
            Image(systemName: isRunning ? "play.circle.fill" : "stop.circle")
                .foregroundStyle(isRunning ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Now")
                    .font(.body.weight(.medium))
                Text("The current state")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("snapshot.current")
    }
}

/// One snapshot: its details and description, rollback and deletion.
private struct SnapshotDetailView: View {
    let detail: GuestDetail
    let snapshot: GuestSnapshot
    @State private var description: String
    @State private var startAfterRollback = false
    @State private var confirmsRollback = false
    @State private var confirmsDeletion = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(detail: GuestDetail, snapshot: GuestSnapshot) {
        self.detail = detail
        self.snapshot = snapshot
        _description = State(initialValue: snapshot.description)
    }

    private var isVM: Bool { detail.reference.kind == .virtualMachine }
    private var canRollBack: Bool { detail.can("VM.Snapshot") || detail.can("VM.Snapshot.Rollback") }

    var body: some View {
        Form {
            Section {
                if let date = snapshot.date {
                    LabeledContent("Taken", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if let parent = snapshot.parent {
                    LabeledContent("Based On", value: parent)
                }
                if isVM {
                    LabeledContent("Includes RAM", value: snapshot.includesRAM ? String(localized: "Yes") : String(localized: "No"))
                }
            }
            Section {
                TextField("None", text: $description, axis: .vertical)
                    .lineLimit(2...6)
                    .disabled(!detail.can("VM.Snapshot"))
                if description.trimmingCharacters(in: .whitespacesAndNewlines) != snapshot.description {
                    Button("Save Description") { Task { await saveDescription() } }
                }
            } header: {
                Text("Description")
            }
            if canRollBack {
                Section {
                    if !snapshot.includesRAM {
                        Toggle("Start After Rollback", isOn: $startAfterRollback)
                    }
                    Button("Roll Back to This Snapshot") { confirmsRollback = true }
                        .accessibilityIdentifier("snapshot.rollback")
                } footer: {
                    Text(snapshot.includesRAM
                        ? "The guest returns to this snapshot and resumes running from its saved memory."
                        : "The guest returns to this snapshot and is stopped, unless you start it after the rollback.")
                }
            }
            if detail.can("VM.Snapshot") {
                Section {
                    Button("Delete Snapshot", role: .destructive) { confirmsDeletion = true }
                        .accessibilityIdentifier("snapshot.delete")
                }
            }
            if isWorking {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Working…")
                    }
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(snapshot.name)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .alert("Roll back to \(snapshot.name)?", isPresented: $confirmsRollback) {
            Button("Cancel", role: .cancel) {}
            Button("Roll Back", role: .destructive) {
                Task { await perform(PVE.rollbackSnapshot(detail.reference, name: snapshot.name, start: startAfterRollback && !snapshot.includesRAM), closes: true) }
            }
            .accessibilityIdentifier("snapshot.rollback.confirm")
        } message: {
            Text("All changes since this snapshot are lost, unless you take another snapshot first.")
        }
        .alert("Delete \(snapshot.name)?", isPresented: $confirmsDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await perform(PVE.deleteSnapshot(detail.reference, name: snapshot.name), closes: true) }
            }
        } message: {
            Text("The current state is kept. You can no longer return to this snapshot.")
        }
    }

    private func saveDescription() async {
        await perform(PVE.updateSnapshotDescription(detail.reference, name: snapshot.name, description: description), closes: false)
    }

    private func perform(_ request: APIRequest<String?>, closes: Bool) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await detail.runSnapshotAction(request)
            if closes { dismiss() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Takes a snapshot. Running VMs can include their memory, like the web interface offers.
private struct TakeSnapshotView: View {
    let detail: GuestDetail
    @State private var name = ""
    @State private var description = ""
    @State private var includeRAM = true
    @State private var showsProblems = false
    @State private var isWorking = false
    @State private var fieldErrors: [String: String] = [:]
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var offersRAM: Bool { detail.reference.kind == .virtualMachine && detail.powerState == .running }
    private var nameProblem: String? { GuestSnapshot.nameProblem(name, existing: detail.snapshots ?? []) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .accessibilityIdentifier("snapshot.name")
                FieldError(message: fieldErrors["snapname"] ?? (showsProblems ? nameProblem : nil))
                TextField("Description (optional)", text: $description, axis: .vertical)
                    .lineLimit(2...6)
            } footer: {
                Text("For example before-upgrade. Letters, digits, - and _, starting with a letter.")
            }
            if offersRAM {
                Section {
                    Toggle("Include RAM", isOn: $includeRAM)
                } footer: {
                    Text("Saves the memory too, so a rollback resumes the running VM. Takes longer and needs space for the memory. Without it, the disks are saved as after a power failure.")
                }
            }
            if isWorking {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Taking snapshot…")
                    }
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Take Snapshot")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .interactiveDismissDisabled(isWorking)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Take", isWorking: isWorking) { Task { await take() } }
                    .accessibilityIdentifier("snapshot.save")
            }
        }
    }

    private func take() async {
        fieldErrors = [:]
        errorMessage = nil
        guard nameProblem == nil else {
            showsProblems = true
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await detail.runSnapshotAction(PVE.createSnapshot(detail.reference, name: name, description: description, includeRAM: offersRAM && includeRAM))
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
