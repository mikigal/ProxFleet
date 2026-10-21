import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// One page of a creation wizard, like a tab of the web interface's Create VM and Create CT dialogs.
nonisolated protocol CreationStep: Hashable, CaseIterable where AllCases == [Self] {
    var title: LocalizedStringKey { get }
    /// Whether a request parameter is set on this page, so its problems and server errors show here.
    func owns(_ parameter: String) -> Bool
}

/// Step-by-step scaffold for creating a guest: a bar with the steps, Back and Next, and on the last step
/// Create with the progress of the creation task.
///
/// Next checks only the current step. Problems found before sending and the server's validation errors use the same
/// parameter names; after a failed Create the wizard goes back to the first step with an error.
struct CreationWizard<Step: CreationStep, Content: View>: View {
    let title: LocalizedStringKey
    let connection: ServerConnection
    let reference: GuestReference
    let problems: [String: String]
    let makeRequest: () -> APIRequest<String>
    let onCreated: (GuestReference) -> Void
    @ViewBuilder let content: (_ step: Step, _ fieldErrors: [String: String]) -> Content

    @State private var step = Step.allCases[0]
    /// The furthest step reached; the step bar lets the user jump back and forth up to it.
    @State private var furthest = 0
    @State private var movesForward = true
    @State private var checkedSteps: Set<Step> = []
    @State private var isSubmitting = false
    @State private var task: TaskCenter.TrackedTask?
    @State private var serverErrors: [String: String] = [:]
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var steps: [Step] { Step.allCases }
    private var index: Int { steps.firstIndex(of: step) ?? 0 }
    private var isLast: Bool { index == steps.count - 1 }
    private var kindName: String { reference.kind == .virtualMachine ? "VM" : "CT" }
    private var isWorking: Bool { isSubmitting || task != nil }

    /// The page each parameter belongs to; keys no page claims show on the last one.
    private func owner(of parameter: String) -> Step {
        steps.dropLast().first { $0.owns(parameter) } ?? steps[steps.count - 1]
    }

    private func problems(on step: Step) -> [String: String] {
        problems.filter { owner(of: $0.key) == step }
    }

    private var fieldErrors: [String: String] {
        problems.filter { checkedSteps.contains(owner(of: $0.key)) }.merging(serverErrors) { _, server in server }
    }

    var body: some View {
        ZStack {
            Form {
                if isLast, let task {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Creating \(kindName) \(String(reference.vmid))…")
                        }
                        NavigationLink("Show Task Log", value: ServerRoute.task(node: task.upid.node, upid: task.upid.rawValue))
                    } footer: {
                        Text("You can close this screen; the server continues in the background.")
                    }
                }
                Group {
                    content(step, fieldErrors)
                }
                .disabled(isWorking)
                ErrorSection(message: errorMessage)
            }
            .id(step)
            .transition(.asymmetric(
                insertion: .move(edge: movesForward ? .trailing : .leading),
                removal: .move(edge: movesForward ? .leading : .trailing)
            ))
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            // A single page, such as cloning, needs no step bar.
            if steps.count > 1 { stepBar }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) { buttons }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isSubmitting)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(task == nil ? "Cancel" : "Close") { dismiss() }
            }
        }
        .onDisappear {
            // The task center reports a failure once nobody here is watching anymore.
            if let task, connection.tasks.tasks.first(where: { $0.id == task.id })?.isRunning == true {
                connection.tasks.reportFailure(of: task.id)
            }
        }
    }

    private var stepBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(steps.enumerated()), id: \.element) { offset, item in
                        Button {
                            go(to: item)
                        } label: {
                            HStack(spacing: 6) {
                                Text(verbatim: "\(offset + 1)")
                                    .monospacedDigit()
                                    .foregroundStyle(item == step ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                                Text(item.title)
                            }
                            .font(.subheadline.weight(item == step ? .semibold : .regular))
                            .padding(.horizontal, 4)
                        }
                        .buttonStyle(StepButtonStyle(isCurrent: item == step, hasProblem: checkedSteps.contains(item) && hasError(on: item)))
                        .disabled(offset > furthest || isWorking)
                        .id(item)
                        .accessibilityIdentifier("step.\(offset)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: step) {
                withAnimation { proxy.scrollTo(step, anchor: .center) }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            if index > 0 {
                Button {
                    go(to: steps[index - 1])
                } label: {
                    Text("Back").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(isWorking)
                .accessibilityIdentifier("back")
            }
            if isLast {
                Button {
                    Task { await create() }
                } label: {
                    Group {
                        if isWorking { ProgressView() } else { Text("Create").fontWeight(.semibold) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(isWorking)
                .accessibilityIdentifier("create")
            } else {
                Button(action: next) {
                    Text("Next").fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("next")
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func hasError(on step: Step) -> Bool {
        !problems(on: step).isEmpty || serverErrors.keys.contains { owner(of: $0) == step }
    }

    /// Moves on when the current step has no problems; otherwise shows them under their fields.
    private func next() {
        checkedSteps.insert(step)
        go(to: steps[index + 1])
    }

    private func go(to target: Step) {
        guard let targetIndex = steps.firstIndex(of: target), targetIndex != index else { return }
        errorMessage = nil
        // Going ahead, also over the bar, stops at the first step with problems.
        if targetIndex > index, let blocked = steps[index..<targetIndex].first(where: { !problems(on: $0).isEmpty }) {
            checkedSteps.insert(blocked)
            errorMessage = String(localized: "Check the highlighted fields.")
            move(to: blocked)
            return
        }
        move(to: target)
    }

    private func move(to target: Step) {
        let targetIndex = steps.firstIndex(of: target) ?? 0
        guard targetIndex != index else { return }
        movesForward = targetIndex > index
        furthest = max(furthest, targetIndex)
        withAnimation(.snappy(duration: 0.3)) { step = target }
    }

    private func create() async {
        errorMessage = nil
        serverErrors = [:]
        checkedSteps.formUnion(steps)
        if let first = steps.first(where: { !problems(on: $0).isEmpty }) {
            errorMessage = String(localized: "Check the highlighted fields.")
            move(to: first)
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
            if let first = steps.first(where: { step in fields.keys.contains { owner(of: $0) == step } }) {
                move(to: first)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A step in the wizard's bar: filled for the current step, red when the step has a problem.
private struct StepButtonStyle: ButtonStyle {
    let isCurrent: Bool
    let hasProblem: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : hasProblem ? AnyShapeStyle(.red) : isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .background {
                Capsule().fill(isCurrent ? AnyShapeStyle(hasProblem ? Color.red : Color.accentColor) : AnyShapeStyle(.fill.tertiary))
            }
            .overlay {
                if hasProblem, !isCurrent { Capsule().strokeBorder(.red.opacity(0.6)) }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The request as it will be sent, like the Confirm tab of the web interface. Secrets are hidden.
struct CreationSummary: View {
    let parameters: APIParameters
    var hidden: Set<String> = ["password"]

    var body: some View {
        Section("Summary") {
            ForEach(parameters.items.sorted { $0.name < $1.name }, id: \.name) { item in
                LabeledContent {
                    Text(hidden.contains(item.name) ? "••••••" : item.value.encoded)
                        .font(.footnote.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                } label: {
                    Text(verbatim: item.name)
                        .font(.footnote.monospaced())
                }
            }
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
    /// Label of an empty choice that leaves the storage to the server, e.g. "Same as Source".
    /// Without it, the first storage is picked.
    var defaultTitle: LocalizedStringKey?
    @State private var storages: [StorageInfo] = []

    var body: some View {
        Picker(title, selection: $selection) {
            if let defaultTitle {
                Text(defaultTitle).tag("")
            }
            if !storages.contains(where: { $0.storage == selection }), !(defaultTitle != nil && selection.isEmpty) {
                Text(selection.isEmpty ? "None" : selection).tag(selection)
            }
            ForEach(storages) { info in
                Text(Self.label(info)).tag(info.storage)
            }
        }
        .task(id: node) {
            storages = await connection.load(PVE.storages(node: node, content: content)).filter(\.isActive)
            if defaultTitle == nil, !storages.contains(where: { $0.storage == selection }) {
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
