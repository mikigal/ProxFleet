import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// Form scaffold for creating a guest: Create button, progress of the creation task, and errors.
///
/// Problems found before sending are shown under their fields after the first attempt;
/// the server's validation errors use the same parameter names.
struct CreationForm<Content: View>: View {
    let title: LocalizedStringKey
    let connection: ServerConnection
    let reference: GuestReference
    let problems: [String: String]
    let makeRequest: () -> APIRequest<String>
    let onCreated: (GuestReference) -> Void
    @ViewBuilder let content: (_ fieldErrors: [String: String]) -> Content

    @State private var isSubmitting = false
    @State private var task: TaskCenter.TrackedTask?
    @State private var showsProblems = false
    @State private var serverErrors: [String: String] = [:]
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var kindName: String { reference.kind == .virtualMachine ? "VM" : "CT" }
    private var isWorking: Bool { isSubmitting || task != nil }

    var body: some View {
        Form {
            if let task {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Creating \(kindName) \(reference.vmid)…")
                    }
                    NavigationLink("Show Task Log", value: ServerRoute.task(node: task.upid.node, upid: task.upid.rawValue))
                } footer: {
                    Text("You can close this screen; the server continues in the background.")
                }
            }
            Group {
                content(showsProblems ? problems.merging(serverErrors) { _, server in server } : serverErrors)
            }
            .disabled(isWorking)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isSubmitting)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(task == nil ? "Cancel" : "Close") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ProgressButton("Create", isWorking: isWorking) { Task { await create() } }
                    .accessibilityIdentifier("create")
            }
        }
        .onDisappear {
            // The task center reports a failure once nobody here is watching anymore.
            if let task, connection.tasks.tasks.first(where: { $0.id == task.id })?.isRunning == true {
                connection.tasks.reportFailure(of: task.id)
            }
        }
    }

    private func create() async {
        errorMessage = nil
        serverErrors = [:]
        guard problems.isEmpty else {
            showsProblems = true
            errorMessage = String(localized: "Check the highlighted fields.")
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let started = try await connection.start(makeRequest())
            task = started
            let result = await connection.tasks.result(of: started.id)
            task = nil
            if case .failed(let message) = result {
                errorMessage = message
            } else {
                onCreated(reference)
                dismiss()
            }
        } catch .invalid(let message, let fields) {
            serverErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Node to create the guest on; only shown for clusters.
struct NodePicker: View {
    let connection: ServerConnection
    @Binding var selection: String

    private var nodes: [NodeSummary] { connection.snapshot?.nodes.filter(\.isOnline) ?? [] }

    var body: some View {
        if (connection.snapshot?.nodes.count ?? 0) > 1 {
            Picker("Node", selection: $selection) {
                ForEach(nodes) { node in
                    Text(node.name).tag(node.name)
                }
            }
        }
    }

    /// The node a new guest goes to unless the user picks another: the one the app is connected to, if online.
    static func defaultNode(_ connection: ServerConnection) -> String {
        let online = connection.snapshot?.nodes.filter(\.isOnline) ?? []
        return (online.first(where: \.isLocal) ?? online.first)?.name ?? ""
    }
}

/// Guest ID, filled with the next free one and checked against the server as it is typed.
struct GuestIDField: View {
    let connection: ServerConnection
    @Binding var vmid: Int
    var error: String?
    @State private var text = ""
    @State private var conflict: String?

    var body: some View {
        LabeledContent("ID") {
            TextField("100", text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .accessibilityIdentifier("vmid")
        }
        .onChange(of: text) { vmid = Int(text) ?? 0 }
        .task {
            if vmid == 0, let next = try? await connection.send(PVE.nextVMID()) {
                vmid = next.value
            }
            if text.isEmpty, vmid > 0 { text = String(vmid) }
        }
        .task(id: vmid) {
            conflict = nil
            guard vmid >= 100 else { return }
            try? await Task.sleep(for: .milliseconds(400))
            do {
                _ = try await connection.send(PVE.checkVMID(vmid))
            } catch ProxmoxError.api(_, _, let fields) where fields["vmid"] != nil {
                conflict = fields["vmid"]
            } catch {}
        }
        FieldError(message: conflict ?? error)
    }
}

/// Resource pool for the new guest; hidden when the server has none.
struct PoolPicker: View {
    let pools: [ResourcePool]
    @Binding var selection: String

    var body: some View {
        if !pools.isEmpty {
            Picker("Resource Pool", selection: $selection) {
                Text("None").tag("")
                ForEach(pools) { pool in
                    Text(pool.id).tag(pool.id)
                }
            }
        }
    }
}

/// Active storages of a node that hold a content type. Picks the first one while nothing valid is selected.
struct NodeStoragePicker: View {
    let title: LocalizedStringKey
    let connection: ServerConnection
    let node: String
    /// `images` for VM disks, `rootdir` for containers, `vztmpl` for templates.
    let content: String
    @Binding var selection: String
    @State private var storages: [StorageInfo] = []

    var body: some View {
        Picker(title, selection: $selection) {
            if !storages.contains(where: { $0.storage == selection }) {
                Text(selection.isEmpty ? "None" : selection).tag(selection)
            }
            ForEach(storages) { info in
                Text(Self.label(info)).tag(info.storage)
            }
        }
        .task(id: node) {
            storages = await connection.load(PVE.storages(node: node, content: content)).filter(\.isActive)
            if !storages.contains(where: { $0.storage == selection }) {
                selection = storages.first?.storage ?? ""
            }
        }
    }

    static func label(_ info: StorageInfo) -> String {
        guard let available = info.available else { return info.storage }
        return "\(info.storage) (\(Format.bytes(available)) free)"
    }
}

/// ISO images or templates on every storage of a node.
struct VolumePicker: View {
    let title: LocalizedStringKey
    /// Label of the empty choice; nil when a volume is required.
    var noneTitle: LocalizedStringKey?
    let connection: ServerConnection
    let node: String
    let content: String
    @Binding var selection: String?
    /// Change it to load the list again, e.g. after a download.
    var reloadID = 0
    @State private var volumes: [StorageVolume] = []
    @State private var isLoading = true

    var body: some View {
        Picker(selection: $selection) {
            if let noneTitle {
                Text(noneTitle).tag(String?.none)
            } else if selection == nil {
                Text("Choose").tag(String?.none)
            }
            ForEach(volumes) { volume in
                Text(volume.fileName).tag(String?.some(volume.volumeID))
            }
        } label: {
            HStack {
                Text(title)
                if isLoading { ProgressView().padding(.leading, 4) }
            }
        }
        .pickerStyle(.navigationLink)
        .task(id: "\(node)/\(reloadID)") {
            isLoading = true
            volumes = await connection.volumes(node: node, content: content)
            isLoading = false
            if let selection, !volumes.contains(where: { $0.volumeID == selection }) {
                self.selection = nil
            }
        }
    }
}

/// Network bridges of a node, with their comments.
struct BridgePicker: View {
    let connection: ServerConnection
    let node: String
    @Binding var selection: String
    @State private var bridges: [NodeNetworkInterface] = []

    var body: some View {
        Picker("Bridge", selection: $selection) {
            ForEach(names, id: \.self) { name in
                Text(bridges.first { $0.name == name }?.comment.flatMap { $0.isEmpty ? nil : "\(name) – \($0)" } ?? name).tag(name)
            }
        }
        .task(id: node) {
            bridges = await connection.load(PVE.bridges(node: node))
            if !bridges.isEmpty, !bridges.contains(where: { $0.name == selection }) {
                selection = bridges[0].name
            }
        }
    }

    private var names: [String] {
        var names = bridges.map(\.name)
        if !names.contains(selection) { names.insert(selection, at: 0) }
        return names
    }
}

/// Optional whole number, e.g. a VLAN tag, edited as text.
struct OptionalNumberField: View {
    let title: LocalizedStringKey
    let placeholder: LocalizedStringKey
    @Binding var value: Int?
    @State private var text = ""

    var body: some View {
        LabeledContent(title) {
            TextField(placeholder, text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
        .onAppear { text = value.map(String.init) ?? "" }
        .onChange(of: text) { value = Int(text) }
    }
}
