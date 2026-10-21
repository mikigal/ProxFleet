import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// The node's network interfaces. Changes are staged in `/etc/network/interfaces.new` until applied.
struct NodeNetworkView: View {
    let detail: NodeDetail
    @State private var creating: NetworkInterfaceDraft.Kind?
    @State private var deleting: NetworkInterface?
    @State private var confirmsApply = false
    @State private var confirmsRevert = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var canModify: Bool { detail.can("Sys.Modify") }

    private static let groups: [(title: LocalizedStringKey, types: Set<String>)] = [
        ("Bridges", ["bridge", "OVSBridge"]),
        ("Bonds", ["bond", "OVSBond"]),
        ("VLANs", ["vlan"]),
        ("Physical Interfaces", ["eth"]),
    ]

    var body: some View {
        List {
            if let network = detail.network {
                if let changes = network.pendingChanges {
                    pendingSection(changes)
                }
                ForEach(Self.groups, id: \.types) { group in
                    let interfaces = network.sortedInterfaces.filter { group.types.contains($0.type) }
                    if !interfaces.isEmpty {
                        Section(group.title) {
                            ForEach(interfaces) { row($0, in: network) }
                        }
                    }
                }
                let known = Self.groups.reduce(into: Set<String>()) { $0.formUnion($1.types) }
                let others = network.sortedInterfaces.filter { !known.contains($0.type) }
                if !others.isEmpty {
                    Section("Other") {
                        ForEach(others) { row($0, in: network) }
                    }
                }
            }
        }
        .overlay {
            if let errorMessage, detail.network == nil {
                ContentUnavailableView("Cannot Load the Network", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if detail.network == nil {
                ProgressView()
            }
        }
        .navigationTitle("Network")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(NetworkInterfaceDraft.Kind.allCases) { kind in
                        Button(kind.title, systemImage: kind.systemImage) { creating = kind }
                    }
                } label: {
                    Label("Create", systemImage: "plus")
                }
                .disabled(!canModify || detail.network == nil)
                .accessibilityIdentifier("network.add")
            }
        }
        .refreshable { errorMessage = await detail.loadNetwork() }
        .task { errorMessage = await detail.loadNetwork() }
        .sheet(item: $creating) { kind in
            NavigationStack {
                NetworkInterfaceEditor(detail: detail, draft: NetworkInterfaceDraft(creating: kind, existing: detail.network?.interfaces ?? []), isNew: true)
            }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { interface in
            Button("Delete", role: .destructive) { Task { await delete(interface) } }
        } message: { _ in
            Text("The interface is removed when you apply the configuration.")
        }
        .alert("Apply Network Configuration?", isPresented: $confirmsApply) {
            Button("Cancel", role: .cancel) {}
            Button("Apply") { Task { await apply() } }
                .accessibilityIdentifier("network.apply.confirm")
        } message: {
            Text("The node reloads its network. If the new settings are wrong, the node and its guests can lose connectivity, and fixing that may need console access.")
        }
        .alert("Revert Pending Changes?", isPresented: $confirmsRevert) {
            Button("Cancel", role: .cancel) {}
            Button("Revert", role: .destructive) { Task { await revert() } }
        } message: {
            Text("All changes that were not applied yet are discarded.")
        }
        .alert("Network Error", isPresented: Binding(get: { errorMessage != nil && detail.network != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func pendingSection(_ changes: String) -> some View {
        Section {
            Label("Pending changes", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
                .font(.body.weight(.medium))
            NavigationLink("Show Changes") {
                NetworkChangesView(diff: changes)
            }
            .accessibilityIdentifier("network.changes")
            HStack {
                Button("Apply Configuration") { confirmsApply = true }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("network.apply")
                Spacer()
                if isWorking { ProgressView() }
            }
            Button("Revert", role: .destructive) { confirmsRevert = true }
                .accessibilityIdentifier("network.revert")
        } footer: {
            Text("Changes are written to /etc/network/interfaces.new and take effect when applied.")
        }
        .disabled(isWorking || !canModify)
    }

    private func row(_ interface: NetworkInterface, in network: NetworkConfiguration) -> some View {
        NavigationLink {
            NetworkInterfaceEditor(detail: detail, draft: NetworkInterfaceDraft(interface), isNew: false, interface: interface)
        } label: {
            NetworkInterfaceRow(interface: interface)
        }
        .accessibilityIdentifier("interface.\(interface.name)")
        .swipeActions {
            if interface.isRemovable, canModify {
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = interface }
            }
        }
    }

    private func perform(_ action: () async throws(ConfigUpdateError) -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply() async { await perform { () throws(ConfigUpdateError) in try await detail.applyNetwork() } }
    private func revert() async { await perform { () throws(ConfigUpdateError) in try await detail.revertNetwork() } }
    private func delete(_ interface: NetworkInterface) async {
        await perform { () throws(ConfigUpdateError) in try await detail.deleteInterface(interface.name) }
    }
}

private struct NetworkInterfaceRow: View {
    let interface: NetworkInterface

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: interface.systemImage)
                .font(.title3)
                .foregroundStyle(interface.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(interface.name)
                        .font(.body.weight(.medium))
                    if let comments = interface.comments {
                        Text(comments)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !interface.isActive {
                Text(interface.exists == false ? "Missing" : "Inactive")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.15), in: .capsule)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts: [String] = [interface.typeTitle]
        if let cidr = interface.cidr { parts.append(cidr) }
        if let cidr6 = interface.cidr6 { parts.append(cidr6) }
        let members = interface.bridgePorts + interface.bondSlaves
        if !members.isEmpty { parts.append(members.joined(separator: ", ")) }
        if let parent = interface.vlanRawDevice { parts.append(String(localized: "on \(parent)")) }
        if interface.bridgeVLANAware { parts.append(String(localized: "VLAN aware")) }
        return parts.joined(separator: " · ")
    }
}

extension NetworkInterface {
    var typeTitle: String {
        switch type {
        case "eth": String(localized: "Network Device")
        case "bridge": String(localized: "Linux Bridge")
        case "bond": String(localized: "Linux Bond")
        case "vlan": String(localized: "Linux VLAN")
        case "alias": String(localized: "Alias")
        case "OVSBridge": String(localized: "OVS Bridge")
        case "OVSBond": String(localized: "OVS Bond")
        case "OVSPort": String(localized: "OVS Port")
        case "OVSIntPort": String(localized: "OVS IntPort")
        default: type
        }
    }

    var systemImage: String {
        switch type {
        case "eth": "cable.connector"
        case "bridge", "OVSBridge": "point.3.connected.trianglepath.dotted"
        case "bond", "OVSBond": "link"
        case "vlan": "tag"
        default: "network"
        }
    }
}

extension NetworkInterfaceDraft.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .bridge: "Linux Bridge"
        case .bond: "Linux Bond"
        case .vlan: "Linux VLAN"
        }
    }

    var systemImage: String {
        switch self {
        case .bridge: "point.3.connected.trianglepath.dotted"
        case .bond: "link"
        case .vlan: "tag"
        }
    }
}

/// The diff between the active and the pending configuration.
private struct NetworkChangesView: View {
    let diff: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line).replacingOccurrences(of: "\t", with: "    "))
                        .font(.caption.monospaced())
                        .foregroundStyle(color(of: line))
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(of: line))
                }
            }
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
        .navigationTitle("Pending Changes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func color(of line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("@@") { return .blue }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return .primary
    }

    private func background(of line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return .green.opacity(0.1) }
        if line.hasPrefix("-") { return .red.opacity(0.1) }
        return .clear
    }
}

// MARK: - Editor

/// Creates or edits an interface. Physical interfaces only get addresses, MTU, autostart and a comment.
struct NetworkInterfaceEditor: View {
    let detail: NodeDetail
    let isNew: Bool
    var interface: NetworkInterface?
    let original: NetworkInterfaceDraft
    @State private var draft: NetworkInterfaceDraft
    @Environment(\.dismiss) private var dismiss

    init(detail: NodeDetail, draft: NetworkInterfaceDraft, isNew: Bool, interface: NetworkInterface? = nil) {
        self.detail = detail
        self.isNew = isNew
        self.interface = interface
        original = draft
        _draft = State(initialValue: draft)
    }

    private var network: NetworkConfiguration? { detail.network }

    var body: some View {
        NodeSettingsForm(title: isNew ? "New \(typeTitle)" : LocalizedStringKey(draft.name), detail: detail, hasChanges: isNew || draft != original, problems: draft.problems) { () throws(ConfigUpdateError) in
            if isNew {
                try await detail.createInterface(draft)
            } else {
                let update = draft.changes(from: original)
                guard !update.isEmpty else { return }
                try await detail.updateInterface(draft.name, type: draft.type, update)
            }
        } content: { errors in
            generalSection(errors)
            if draft.isBridge { bridgeSection(errors) }
            if draft.isBond { bondSection(errors) }
            if draft.isVLAN { vlanSection(errors) }
            addressSections(errors)
            Section {
                LabeledTextField(title: "MTU", prompt: "1500", text: $draft.mtu, keyboard: .numberPad, identifier: "interface.mtu")
                FieldError(message: errors["mtu"])
            } footer: {
                Text("Leave empty for the default.")
            }
            if let interface, interface.isOVS {
                Section {
                } footer: {
                    Text("Open vSwitch ports, bonds and options can be changed in the web interface.")
                }
            }
            Section {
            } footer: {
                Text("Changes take effect when you apply the configuration in the network list.")
            }
        }
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var typeTitle: String {
        NetworkInterfaceDraft.Kind(rawValue: draft.type).map { String(localized: $0.titleResource) } ?? draft.type
    }

    @ViewBuilder
    private func generalSection(_ errors: [String: String]) -> some View {
        Section {
            if isNew {
                LabeledTextField(title: "Name", prompt: draft.isVLAN ? "vmbr0.20" : "", text: $draft.name, identifier: "interface.name")
                FieldError(message: errors["iface"])
            } else if let interface {
                LabeledContent("Type", value: interface.typeTitle)
                if !interface.altNames.isEmpty {
                    LabeledContent("Alternative Names", value: interface.altNames.joined(separator: ", "))
                }
                LabeledContent("Active", value: interface.isActive ? String(localized: "Yes") : String(localized: "No"))
            }
            Toggle("Autostart", isOn: $draft.autostart)
            LabeledContent("Comment") {
                TextField("Comment", text: $draft.comments, prompt: Text("None"))
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("interface.comment")
            }
        }
    }

    @ViewBuilder
    private func addressSections(_ errors: [String: String]) -> some View {
        Section {
            LabeledTextField(title: "Address", prompt: "192.168.1.10/24", text: $draft.cidr, keyboard: .numbersAndPunctuation, identifier: "interface.cidr")
            FieldError(message: errors["cidr"])
            LabeledTextField(title: "Gateway", prompt: "None", text: $draft.gateway, keyboard: .numbersAndPunctuation, identifier: "interface.gateway")
            FieldError(message: errors["gateway"])
        } header: {
            Text("IPv4")
        } footer: {
            Text("Address with prefix length. Leave empty for none. A node has one default gateway.")
        }
        Section("IPv6") {
            LabeledTextField(title: "Address", prompt: "fd00::10/64", text: $draft.cidr6, keyboard: .numbersAndPunctuation)
            FieldError(message: errors["cidr6"])
            LabeledTextField(title: "Gateway", prompt: "None", text: $draft.gateway6, keyboard: .numbersAndPunctuation)
            FieldError(message: errors["gateway6"])
        }
    }

    /// Interfaces that can be added as ports or members, plus the ones already chosen.
    private func candidates(chosen: [String]) -> [String] {
        let free = network?.freeInterfaces(excluding: draft.name) ?? []
        return (chosen + free.filter { !chosen.contains($0) }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    @ViewBuilder
    private func bridgeSection(_ errors: [String: String]) -> some View {
        Section {
            MemberPicker(candidates: candidates(chosen: draft.bridgePorts), selection: $draft.bridgePorts)
            FieldError(message: errors["bridge_ports"])
        } header: {
            Text("Bridge Ports")
        } footer: {
            Text("A bridge without ports connects only the guests on this node.")
        }
        Section {
            Toggle("VLAN Aware", isOn: $draft.vlanAware)
                .accessibilityIdentifier("interface.vlanAware")
            if draft.vlanAware {
                LabeledTextField(title: "VLAN IDs", prompt: "2-4094", text: $draft.bridgeVIDs, keyboard: .numbersAndPunctuation)
                FieldError(message: errors["bridge_vids"])
            }
        } footer: {
            Text("A VLAN-aware bridge passes tagged traffic, so guests can set a VLAN tag on their network device.")
        }
    }

    @ViewBuilder
    private func bondSection(_ errors: [String: String]) -> some View {
        Section {
            Picker("Mode", selection: $draft.bondMode) {
                ForEach(BondMode.all, id: \.self) { Text($0).tag($0) }
            }
            if BondMode.usesHashPolicy(draft.bondMode) {
                Picker("Hash Policy", selection: $draft.hashPolicy) {
                    Text("Default").tag("")
                    ForEach(BondMode.hashPolicies, id: \.self) { Text($0).tag($0) }
                }
            }
            if draft.bondMode == "active-backup" {
                Picker("Primary", selection: $draft.bondPrimary) {
                    Text("None").tag("")
                    ForEach(draft.bondSlaves, id: \.self) { Text($0).tag($0) }
                }
            }
            FieldError(message: errors["bond_mode"])
        } header: {
            Text("Bond")
        } footer: {
            Text("802.3ad (LACP) needs a matching setup on the switch.")
        }
        Section("Members") {
            MemberPicker(candidates: candidates(chosen: draft.bondSlaves), selection: $draft.bondSlaves)
            FieldError(message: errors["slaves"])
        }
    }

    @ViewBuilder
    private func vlanSection(_ errors: [String: String]) -> some View {
        Section {
            if draft.namesVLAN {
                let parts = draft.name.split(separator: ".")
                LabeledContent("Parent", value: parts.dropLast().joined(separator: "."))
                LabeledContent("VLAN Tag", value: String(parts.last ?? ""))
            } else {
                Picker("Parent", selection: $draft.vlanRawDevice) {
                    Text("Choose").tag("")
                    ForEach((network?.sortedInterfaces ?? []).filter { $0.name != draft.name && $0.type != "vlan" }) { Text($0.name).tag($0.name) }
                }
                FieldError(message: errors["vlan-raw-device"])
                LabeledTextField(title: "VLAN Tag", prompt: "1–4094", text: $draft.vlanID, keyboard: .numberPad)
                FieldError(message: errors["vlan-id"])
            }
        } header: {
            Text("VLAN")
        } footer: {
            Text("Name the interface after its parent and tag, such as vmbr0.20, or choose any name and set both here.")
        }
    }
}

extension NetworkInterfaceDraft.Kind {
    var titleResource: LocalizedStringResource {
        switch self {
        case .bridge: "Linux Bridge"
        case .bond: "Linux Bond"
        case .vlan: "Linux VLAN"
        }
    }
}

/// Checkmark list for bridge ports and bond members.
private struct MemberPicker: View {
    let candidates: [String]
    @Binding var selection: [String]

    var body: some View {
        if candidates.isEmpty {
            Text("No free interfaces")
                .foregroundStyle(.secondary)
        }
        ForEach(candidates, id: \.self) { name in
            Button {
                if let index = selection.firstIndex(of: name) {
                    selection.remove(at: index)
                } else {
                    selection.append(name)
                }
            } label: {
                HStack {
                    Text(name)
                        .foregroundStyle(.primary)
                    Spacer()
                    if selection.contains(name) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                            .fontWeight(.semibold)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("member.\(name)")
            .accessibilityAddTraits(selection.contains(name) ? .isSelected : [])
        }
    }
}
