import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// The single page of the clone form.
nonisolated enum CloneStep: CreationStep {
    case clone

    var title: LocalizedStringKey { "Clone" }

    func owns(_ parameter: String) -> Bool { true }
}

/// Clones a VM or container, like the web interface's Clone dialog. Templates clone linked by default.
struct CloneView: View {
    let detail: GuestDetail
    let onCreated: (GuestReference) -> Void
    @State private var draft: CloneDraft
    @State private var pools: [ResourcePool] = []
    @State private var snapshots: [GuestSnapshot] = []

    init(detail: GuestDetail, onCreated: @escaping (GuestReference) -> Void) {
        self.detail = detail
        self.onCreated = onCreated
        _draft = State(initialValue: CloneDraft(source: detail.reference, isTemplate: detail.isTemplate))
    }

    private var connection: ServerConnection { detail.connection }
    private var isVM: Bool { detail.reference.kind == .virtualMachine }
    private var nameKey: String { isVM ? "name" : "hostname" }

    var body: some View {
        CreationWizard<CloneStep, _>(
            title: isVM ? "Clone VM \(String(detail.reference.vmid))" : "Clone CT \(String(detail.reference.vmid))",
            connection: connection,
            reference: GuestReference(node: draft.targetNode, vmid: draft.vmid, kind: detail.reference.kind),
            problems: draft.problems,
            makeRequest: { PVE.clone(draft) },
            onCreated: onCreated
        ) { _, errors in
            Section {
                LabeledContent("Source", value: "\(detail.reference.vmid) · \(detail.name)")
                NodePicker(connection: connection, selection: $draft.targetNode)
                FieldError(message: errors["target"])
                GuestIDField(connection: connection, vmid: $draft.vmid, error: errors["newid"])
                LabeledContent(isVM ? "Name" : "Host Name") {
                    TextField("Optional", text: $draft.name)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("clone.name")
                }
                FieldError(message: errors[nameKey])
                PoolPicker(pools: pools, selection: $draft.pool)
            } footer: {
                if draft.targetNode != detail.reference.node {
                    Text("Cloning to another node needs the disks on shared storage.")
                }
            }
            .task { pools = await connection.load(PVE.pools()) }

            Section {
                if draft.sourceIsTemplate {
                    Picker("Mode", selection: $draft.fullClone) {
                        Text("Linked Clone").tag(false)
                        Text("Full Clone").tag(true)
                    }
                    .accessibilityIdentifier("clone.mode")
                }
                if draft.fullClone {
                    NodeStoragePicker(title: "Target Storage", connection: connection, node: draft.targetNode, content: isVM ? "images" : "rootdir", selection: $draft.storage, defaultTitle: "Same as Source")
                    FieldError(message: errors["storage"])
                }
                if !draft.sourceIsTemplate, snapshots.count > 1 {
                    Picker("State", selection: $draft.snapshot) {
                        Text("Current State").tag(String?.none)
                        ForEach(snapshots.filter { !$0.isCurrent }) { snapshot in
                            Text(snapshot.name).tag(String?.some(snapshot.name))
                        }
                    }
                    FieldError(message: errors["snapname"])
                }
            } header: {
                Text("Disks")
            } footer: {
                if draft.sourceIsTemplate {
                    Text(draft.fullClone
                        ? "A full clone copies the disks and does not depend on the template."
                        : "A linked clone shares the template's disks and stores only its own changes. It is quick and saves space, but the template cannot be deleted while clones use it.")
                } else {
                    Text("The disks are copied. A running guest can be cloned, but its disks may change while they are copied.")
                }
            }
            .task {
                guard !draft.sourceIsTemplate else { return }
                snapshots = (try? await connection.send(PVE.snapshots(detail.reference))) ?? []
            }
        }
    }
}
