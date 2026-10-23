import FleetCore
import PVEKit
import SwiftUI

/// Moves a guest to another node of the cluster, like the web interface's Migrate dialog: running VMs move live,
/// running containers restart on the target, and the checks of the chosen target show below.
struct MigrateView: View {
    let detail: GuestDetail
    @State private var draft: MigrationDraft
    @State private var isLoading = false
    @State private var isStarting = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(detail: GuestDetail) {
        self.detail = detail
        let source = detail.reference.node
        let target = detail.connection.snapshot?.nodes.first { $0.isOnline && $0.name != source }?.name ?? ""
        _draft = State(initialValue: MigrationDraft(guest: detail.reference, target: target))
    }

    private var isVM: Bool { detail.reference.kind == .virtualMachine }
    private var targets: [NodeSummary] {
        detail.connection.snapshot?.nodes.filter { $0.isOnline && $0.name != detail.reference.node } ?? []
    }
    /// Forcing a migration with host devices is limited to root@pam.
    private var isRoot: Bool { detail.connection.profile.userID == "root@pam" }

    var body: some View {
        Form {
            if targets.isEmpty {
                ContentUnavailableView("No Other Node Online", systemImage: "server.rack", description: Text("Guests can only move to another online node of the cluster."))
            } else {
                Section {
                    LabeledContent("Source", value: detail.reference.node)
                    Picker("Target", selection: $draft.target) {
                        ForEach(targets) { node in
                            Text(node.name).tag(node.name)
                        }
                    }
                    .accessibilityIdentifier("migrate.target")
                    LabeledContent("Mode") {
                        if isLoading && draft.preconditions == nil {
                            ProgressView()
                        } else {
                            Text(modeTitle)
                        }
                    }
                    .accessibilityIdentifier("migrate.mode")
                } footer: {
                    Text(modeFooter)
                }
                if draft.showsTargetStorage || (draft.showsForce && isRoot) || draft.showsConntrackState {
                    Section {
                        if draft.showsTargetStorage {
                            NodeStoragePicker(
                                title: "Target Storage", connection: detail.connection, node: draft.target, content: "images",
                                selection: $draft.targetStorage, defaultTitle: "Current Layout"
                            )
                        }
                        if draft.showsForce, isRoot {
                            Toggle("Force", isOn: $draft.force)
                                .accessibilityIdentifier("migrate.force")
                        }
                        if draft.showsConntrackState {
                            Toggle("Conntrack State", isOn: $draft.withConntrackState)
                                .accessibilityIdentifier("migrate.conntrack")
                        }
                    } footer: {
                        Text(optionsFooter)
                    }
                }
                if !draft.notes.isEmpty {
                    Section("Checks") {
                        ForEach(draft.notes) { note in
                            Label {
                                Text(note.text)
                            } icon: {
                                Image(systemName: icon(note.severity)).foregroundStyle(color(note.severity))
                            }
                            .accessibilityIdentifier("migrate.note")
                        }
                    }
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isVM ? "Migrate VM \(String(detail.reference.vmid))" : "Migrate CT \(String(detail.reference.vmid))")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isStarting)
        .disabled(isStarting)
        .task(id: draft.target) { await loadPreconditions() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Migrate", isWorking: isStarting) { Task { await migrate() } }
                    .disabled(!draft.canMigrate || isLoading)
                    .accessibilityIdentifier("migrate.confirm")
            }
        }
    }

    private var modeTitle: LocalizedStringKey {
        switch draft.mode {
        case .online: "Online"
        case .restart: "Restart"
        case .offline: "Offline"
        }
    }

    private var modeFooter: LocalizedStringKey {
        switch draft.mode {
        case .online: "The VM keeps running while its memory is copied to the target, and pauses only briefly at the end."
        case .restart: "The container shuts down, moves and starts again on the target."
        case .offline: "The stopped guest moves with its configuration. Disks on local storage are copied."
        }
    }

    private var optionsFooter: String {
        var lines: [String] = []
        if draft.showsTargetStorage {
            lines.append(String(localized: "Current Layout keeps every disk on a storage of the same name on the target."))
        }
        if draft.showsForce, isRoot {
            lines.append(String(localized: "Force migrates even with host devices, which may not exist on the target."))
        }
        if draft.showsConntrackState {
            lines.append(String(localized: "Conntrack State carries the VM's tracked connections along, so they keep working."))
        }
        return lines.joined(separator: " ")
    }

    private func icon(_ severity: MigrationNote.Severity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private func color(_ severity: MigrationNote.Severity) -> Color {
        switch severity {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        }
    }

    private func loadPreconditions() async {
        guard !draft.target.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (preconditions, supportsConntrack) = try await detail.migrationPreconditions(target: draft.target)
            draft.preconditions = preconditions
            draft.targetSupportsConntrackState = supportsConntrack
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            draft.preconditions = nil
            errorMessage = error.localizedDescription
        }
    }

    private func migrate() async {
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }
        do {
            try await detail.migrate(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
