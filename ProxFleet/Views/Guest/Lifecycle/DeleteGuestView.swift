import FleetCore
import PVEKit
import SwiftUI

/// Deletes a stopped guest after the user types its ID, like the web interface's Destroy dialog.
struct DeleteGuestView: View {
    let detail: GuestDetail
    let onDeleted: () -> Void
    @State private var purge = true
    @State private var destroyUnreferencedDisks = true
    @State private var confirmation = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var isVM: Bool { detail.reference.kind == .virtualMachine }
    private var kindName: String { isVM ? String(localized: "VM") : String(localized: "CT") }
    private var isStopped: Bool { detail.powerState == .stopped }
    private var isConfirmed: Bool { confirmation.trimmingCharacters(in: .whitespaces) == String(detail.reference.vmid) }

    var body: some View {
        Form {
            Section {
                Label {
                    Text("\(kindName) \(String(detail.reference.vmid)) “\(detail.name)” and all its disks and snapshots are deleted permanently. This cannot be undone.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            if !isStopped {
                Section {
                    Label("Stop the guest before deleting it.", systemImage: "stop.circle")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Toggle("Remove from Jobs and HA", isOn: $purge)
                Toggle("Delete Unreferenced Disks", isOn: $destroyUnreferencedDisks)
            } footer: {
                Text("The first removes the guest from backup and replication jobs, HA and permissions. The second also deletes disks with this guest's ID that its configuration no longer lists.")
            }
            Section {
                TextField(String(detail.reference.vmid), text: $confirmation)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("delete.confirmation")
            } header: {
                Text("Type \(String(detail.reference.vmid)) to Confirm")
            }
            Section {
                Button(role: .destructive) {
                    Task { await delete() }
                } label: {
                    HStack {
                        Text("Delete \(kindName) \(String(detail.reference.vmid))")
                        Spacer()
                        if isDeleting { ProgressView() }
                    }
                }
                .disabled(!isConfirmed || !isStopped || isDeleting)
                .accessibilityIdentifier("delete.confirm")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle("Delete \(kindName)")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isDeleting)
        .disabled(isDeleting)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func delete() async {
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }
        do {
            try await detail.destroy(purge: purge, destroyUnreferencedDisks: destroyUnreferencedDisks)
            onDeleted()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
