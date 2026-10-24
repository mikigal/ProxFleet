import FleetCore
import PVEKit
import SwiftUI

/// The web interface's Bulk Start, Bulk Shutdown, Bulk Suspend and Bulk Migrate dialogs: choose guests of a node, or
/// of every node, and run the action for all of them in one task.
struct NodeBulkActionView: View {
    let action: NodeBulkAction
    /// nil for the datacenter's bulk actions.
    let node: String?
    /// Before PVE 9.2, only migrations take a number of parallel jobs.
    private let offersParallelJobs: Bool
    private let run: (NodeBulkActionDraft) async throws(ConfigUpdateError) -> Void
    private let guests: [GuestSummary]
    private let targets: [String]
    @State private var draft: NodeBulkActionDraft
    @State private var timeoutText = ""
    @State private var isStarting = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(detail: NodeDetail, action: NodeBulkAction) {
        self.init(connection: detail.connection, node: detail.node, action: action) { draft throws(ConfigUpdateError) in
            _ = try await detail.run(draft)
        }
    }

    init(connection: ServerConnection, node: String?, action: NodeBulkAction, run: @escaping (NodeBulkActionDraft) async throws(ConfigUpdateError) -> Void) {
        self.action = action
        self.node = node
        self.run = run
        offersParallelJobs = action == .migrate || connection.supports(.bulkActionParallelJobs)
        let guests = connection.snapshot.map { action.eligibleGuests(on: node, in: $0) } ?? []
        self.guests = guests
        let targets = connection.snapshot?.nodes.filter { $0.isOnline && $0.name != node }.map(\.name) ?? []
        self.targets = targets
        var draft = NodeBulkActionDraft(action: action, vmids: Set(guests.map(\.vmid)))
        draft.target = targets.first ?? ""
        _draft = State(initialValue: draft)
    }

    /// The guests to choose from: for migration, those not on the target already, which Proxmox would skip.
    private var shownGuests: [GuestSummary] {
        action == .migrate ? guests.filter { $0.node != draft.target } : guests
    }

    private var chosenIDs: Set<Int> { draft.vmids.intersection(shownGuests.map(\.vmid)) }

    private var title: LocalizedStringKey {
        switch action {
        case .start: "Bulk Start"
        case .shutdown: "Bulk Shutdown"
        case .hibernate: "Bulk Hibernate"
        case .migrate: "Bulk Migrate"
        }
    }

    private var confirmTitle: LocalizedStringKey {
        switch action {
        case .start: "Start"
        case .shutdown: "Shut Down"
        case .hibernate: "Hibernate"
        case .migrate: "Migrate"
        }
    }

    var body: some View {
        Form {
            if action == .migrate, !targets.isEmpty {
                Section {
                    Picker("Target", selection: $draft.target) {
                        ForEach(targets, id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("bulk.target")
                    Toggle("Allow Local Disk Migration", isOn: $draft.withLocalDisks)
                        .accessibilityIdentifier("bulk.localDisks")
                } footer: {
                    Text("Disks on local storage are copied to the target. Without it, VMs with local disks fail to migrate.")
                }
            }
            if shownGuests.isEmpty || (action == .migrate && targets.isEmpty) {
                ContentUnavailableView(emptyTitle, systemImage: "square.stack.3d.up.slash")
            } else {
                Section {
                    ForEach(shownGuests) { guest in
                        Button {
                            if draft.vmids.contains(guest.vmid) { draft.vmids.remove(guest.vmid) } else { draft.vmids.insert(guest.vmid) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: draft.vmids.contains(guest.vmid) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(draft.vmids.contains(guest.vmid) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    .font(.title3)
                                Image(systemName: guest.kind == .virtualMachine ? "desktopcomputer" : "shippingbox")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(guest.name.isEmpty ? String(guest.vmid) : guest.name)
                                        .foregroundStyle(.primary)
                                    Text("\(guest.kind == .virtualMachine ? String(localized: "VM") : String(localized: "CT")) \(String(guest.vmid))\(node == nil ? " · \(guest.node)" : "")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("bulk.guest.\(guest.vmid)")
                        .accessibilityAddTraits(draft.vmids.contains(guest.vmid) ? .isSelected : [])
                    }
                } header: {
                    HStack {
                        Text("Guests")
                        Spacer()
                        Button(chosenIDs.count == shownGuests.count ? "Select None" : "Select All") {
                            draft.vmids = chosenIDs.count == shownGuests.count ? [] : Set(shownGuests.map(\.vmid))
                        }
                        .font(.footnote)
                        .textCase(nil)
                    }
                } footer: {
                    Text(footer)
                }
                if offersParallelJobs || action == .shutdown {
                    Section {
                        if offersParallelJobs {
                            Picker("Parallel Jobs", selection: $draft.maxWorkers) {
                                // Migrating always needs a number, as in the web interface.
                                if action != .migrate {
                                    Text("Default").tag(Int?.none)
                                }
                                ForEach([1, 2, 4, 8, 16], id: \.self) { Text(String($0)).tag(Int?.some($0)) }
                            }
                        }
                        if action == .shutdown {
                            LabeledTextField(title: "Timeout", prompt: "180 s", text: $timeoutText, keyboard: .numberPad, identifier: "bulk.timeout")
                            Toggle("Force Stop After Timeout", isOn: $draft.forceStop)
                        }
                    } footer: {
                        switch action {
                        case .shutdown:
                            Text("Guests that have their own shutdown timeout use it instead. Without Force Stop, guests still running after the timeout are left running.")
                        case .migrate:
                            Text("Migrations at the same time. Each one copies memory and local disks over the network.")
                        default:
                            Text("Without a number, the datacenter's maximum workers setting applies.")
                        }
                    }
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isStarting)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton(confirmTitle, isWorking: isStarting) { Task { await run() } }
                    .disabled(chosenIDs.isEmpty || (action == .migrate && draft.target.isEmpty))
                    .accessibilityIdentifier("bulk.confirm")
            }
        }
    }

    private var emptyTitle: LocalizedStringKey {
        switch action {
        case .start: "No Stopped Guests"
        case .shutdown: "No Running Guests"
        case .hibernate: "No Running VMs"
        case .migrate: targets.isEmpty ? "No Other Node Online" : "No Guests to Migrate"
        }
    }

    private var footer: String {
        switch action {
        case .start: String(localized: "Guests start in their start order, also those not set to start at boot.")
        case .shutdown: String(localized: "Guests shut down in reverse start order.")
        case .hibernate: String(localized: "VMs save their memory to disk and stop; starting them resumes where they left off. Containers cannot be hibernated.")
        case .migrate:
            shownGuests.contains { chosenIDs.contains($0.vmid) && $0.kind == .container && $0.state == .running }
                ? String(localized: "Running VMs move live. Running containers are migrated in restart mode: they shut down, move and start again.")
                : String(localized: "Running VMs move live, stopped guests offline.")
        }
    }

    private func run() async {
        let timeout = timeoutText.trimmingCharacters(in: .whitespaces)
        if !timeout.isEmpty {
            guard let seconds = Int(timeout), (0...7200).contains(seconds) else {
                errorMessage = String(localized: "Enter a timeout between 0 and 7200 seconds.")
                return
            }
            draft.timeout = seconds
        } else {
            draft.timeout = nil
        }
        draft.vmids = chosenIDs
        isStarting = true
        defer { isStarting = false }
        do {
            try await run(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
