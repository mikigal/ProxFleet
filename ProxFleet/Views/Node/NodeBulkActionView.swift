import FleetCore
import PVEKit
import SwiftUI

/// The web interface's Bulk Start, Bulk Shutdown and Bulk Suspend dialogs: choose guests of the node and run the
/// action for all of them in one task.
struct NodeBulkActionView: View {
    let detail: NodeDetail
    let action: NodeBulkAction
    private let guests: [GuestSummary]
    @State private var draft: NodeBulkActionDraft
    @State private var timeoutText = ""
    @State private var isStarting = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(detail: NodeDetail, action: NodeBulkAction) {
        self.detail = detail
        self.action = action
        let guests = detail.connection.snapshot.map { action.eligibleGuests(on: detail.node, in: $0) } ?? []
        self.guests = guests
        _draft = State(initialValue: NodeBulkActionDraft(action: action, vmids: Set(guests.map(\.vmid))))
    }

    private var title: LocalizedStringKey {
        switch action {
        case .start: "Bulk Start"
        case .shutdown: "Bulk Shutdown"
        case .hibernate: "Bulk Hibernate"
        }
    }

    private var confirmTitle: LocalizedStringKey {
        switch action {
        case .start: "Start"
        case .shutdown: "Shut Down"
        case .hibernate: "Hibernate"
        }
    }

    var body: some View {
        Form {
            if guests.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "square.stack.3d.up.slash")
            } else {
                Section {
                    ForEach(guests) { guest in
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
                                    Text("\(guest.kind == .virtualMachine ? String(localized: "VM") : String(localized: "CT")) \(String(guest.vmid))")
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
                        Button(draft.vmids.count == guests.count ? "Select None" : "Select All") {
                            draft.vmids = draft.vmids.count == guests.count ? [] : Set(guests.map(\.vmid))
                        }
                        .font(.footnote)
                        .textCase(nil)
                    }
                } footer: {
                    Text(footer)
                }
                Section {
                    Picker("Parallel Jobs", selection: $draft.maxWorkers) {
                        Text("Default").tag(Int?.none)
                        ForEach([1, 2, 4, 8, 16], id: \.self) { Text(String($0)).tag(Int?.some($0)) }
                    }
                    if action == .shutdown {
                        LabeledTextField(title: "Timeout", prompt: "180 s", text: $timeoutText, keyboard: .numberPad, identifier: "bulk.timeout")
                        Toggle("Force Stop After Timeout", isOn: $draft.forceStop)
                    }
                } footer: {
                    Text(action == .shutdown
                        ? "Guests that have their own shutdown timeout use it instead. Without Force Stop, guests still running after the timeout are left running."
                        : "Without a number, the datacenter's maximum workers setting applies.")
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
                    .disabled(draft.vmids.isEmpty)
                    .accessibilityIdentifier("bulk.confirm")
            }
        }
    }

    private var emptyTitle: LocalizedStringKey {
        switch action {
        case .start: "No Stopped Guests"
        case .shutdown: "No Running Guests"
        case .hibernate: "No Running VMs"
        }
    }

    private var footer: String {
        switch action {
        case .start: String(localized: "Guests start in their start order, also those not set to start at boot.")
        case .shutdown: String(localized: "Guests shut down in reverse start order.")
        case .hibernate: String(localized: "VMs save their memory to disk and stop; starting them resumes where they left off. Containers cannot be hibernated.")
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
        isStarting = true
        defer { isStarting = false }
        do {
            try await detail.run(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
