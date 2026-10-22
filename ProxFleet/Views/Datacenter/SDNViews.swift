import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// The datacenter's SDN: zones and VNets with their subnets. Changes stay pending until Apply, as in the web interface.
struct SDNView: View {
    @State private var sdn: SDNSettings
    @State private var creating: Creation?
    @State private var deleting: Deletion?
    @State private var confirmsRevert = false
    @State private var isApplying = false
    @State private var errorMessage: String?

    enum Creation: String, Identifiable {
        case zone, vnet

        var id: String { rawValue }
    }

    enum Deletion: Identifiable {
        case zone(String), vnet(String)

        var id: String {
            switch self {
            case .zone(let id): "zone/\(id)"
            case .vnet(let id): "vnet/\(id)"
            }
        }
    }

    init(connection: ServerConnection) {
        _sdn = State(initialValue: SDNSettings(connection: connection))
    }

    var body: some View {
        List {
            if sdn.hasPendingChanges {
                Section {
                    Label("Changes wait to be applied to the nodes.", systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    Button {
                        Task { await apply() }
                    } label: {
                        HStack {
                            Label("Apply", systemImage: "checkmark.circle")
                            if isApplying { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!sdn.canModify || isApplying)
                    .accessibilityIdentifier("sdn.apply")
                    Button("Revert", systemImage: "arrow.uturn.backward", role: .destructive) { confirmsRevert = true }
                        .disabled(!sdn.canModify || isApplying)
                        .accessibilityIdentifier("sdn.revert")
                } footer: {
                    Text("Apply writes the configuration to every node and reloads their networks.")
                }
            }
            if let zones = sdn.zones {
                Section {
                    if zones.isEmpty {
                        Text("No zones").foregroundStyle(.secondary)
                    }
                    ForEach(zones) { zone in
                        NavigationLink {
                            SDNZoneEditor(sdn: sdn, zone: zone)
                        } label: {
                            ZoneRow(zone: zone, status: status(of: zone.id))
                        }
                        .disabled(zone.state == .deleted)
                        .accessibilityIdentifier("sdn.zone.\(zone.id)")
                        .swipeActions {
                            if sdn.canModify, zone.state != .deleted {
                                Button("Delete", systemImage: "trash") { deleting = .zone(zone.id) }
                                    .tint(.red)
                            }
                        }
                    }
                } header: {
                    Text("Zones")
                } footer: {
                    Text("A zone sets how its VNets reach the network: Simple is an isolated bridge with routing and NAT, VLAN and QinQ tag traffic on an existing bridge, VXLAN tunnels between nodes.")
                }
            }
            if let vnets = sdn.vnets {
                Section {
                    if vnets.isEmpty {
                        Text("No VNets").foregroundStyle(.secondary)
                    }
                    ForEach(vnets) { vnet in
                        NavigationLink {
                            SDNVNetDetailView(sdn: sdn, vnetID: vnet.id)
                        } label: {
                            VNetRow(vnet: vnet, subnets: sdn.subnets[vnet.id] ?? [])
                        }
                        .disabled(vnet.state == .deleted)
                        .accessibilityIdentifier("sdn.vnet.\(vnet.id)")
                        .swipeActions {
                            if sdn.canModify, vnet.state != .deleted {
                                Button("Delete", systemImage: "trash") { deleting = .vnet(vnet.id) }
                                    .tint(.red)
                            }
                        }
                    }
                } header: {
                    Text("VNets")
                } footer: {
                    Text("Guests use a VNet like a bridge: pick it as the bridge of a network device.")
                }
            }
            if !sdn.ipams.isEmpty {
                Section {
                    ForEach(sdn.ipams.filter { $0.type == "pve" }) { ipam in
                        NavigationLink {
                            IPAMView(sdn: sdn, ipam: ipam.id)
                        } label: {
                            MoreRow(title: "IPAM \(ipam.id)", systemImage: "list.number", color: .teal)
                        }
                        .accessibilityIdentifier("sdn.ipam.\(ipam.id)")
                    }
                }
            }
            if let error = sdn.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .overlay { if sdn.zones == nil, sdn.loadError == nil { ProgressView() } }
        .navigationTitle("SDN")
        .refreshable { await sdn.load() }
        .task { await sdn.load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    Button("Zone", systemImage: "square.dashed") { creating = .zone }
                        .accessibilityIdentifier("sdn.add.zone")
                    Button("VNet", systemImage: "point.3.connected.trianglepath.dotted") { creating = .vnet }
                        .disabled(sdn.zones?.isEmpty ?? true)
                        .accessibilityIdentifier("sdn.add.vnet")
                }
                .disabled(!sdn.canModify)
                .accessibilityIdentifier("sdn.add")
            }
        }
        .sheet(item: $creating) { kind in
            NavigationStack {
                switch kind {
                case .zone: SDNZoneEditor(sdn: sdn, zone: nil)
                case .vnet: SDNVNetEditor(sdn: sdn, vnet: nil)
                }
            }
        }
        .confirmationDialog(deletionTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { deletion in
            Button("Delete", role: .destructive) { Task { await delete(deletion) } }
        } message: { _ in
            Text("The deletion takes effect on Apply. Zones with VNets and VNets with subnets cannot be deleted.")
        }
        .confirmationDialog("Revert all pending SDN changes?", isPresented: $confirmsRevert, titleVisibility: .visible) {
            Button("Revert", role: .destructive) { Task { await revert() } }
        } message: {
            Text(revertMessage)
        }
        .alert("SDN Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var deletionTitle: String {
        switch deleting {
        case .zone(let id): String(localized: "Delete the zone \(id)?")
        case .vnet(let id): String(localized: "Delete the VNet \(id)?")
        case nil: ""
        }
    }

    /// Proxmox drops a deleted subnet from the IPAM right away, and a revert does not bring that back.
    private var revertMessage: String {
        let deletesSubnets = sdn.subnets.values.contains { $0.contains { $0.state == .deleted && $0.running.isEmpty == false } }
        return deletesSubnets
            ? String(localized: "Everything returns to the applied configuration. Deleted subnets come back without their IPAM entries, which Proxmox removes right away; such a subnet can then neither be changed nor deleted. Re-create it instead.")
            : String(localized: "Everything returns to the applied configuration.")
    }

    /// One status per zone: the worst any node reports.
    private func status(of zone: String) -> String? {
        let statuses = sdn.zoneStatus.values.compactMap { $0[zone] }
        return statuses.first { $0 != "available" } ?? statuses.first
    }

    private func apply() async {
        isApplying = true
        defer { isApplying = false }
        do {
            let task = try await sdn.apply()
            if case .failed(let message) = await sdn.connection.tasks.result(of: task.id) { errorMessage = message }
            await sdn.load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revert() async {
        do {
            try await sdn.rollback()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ deletion: Deletion) async {
        do {
            switch deletion {
            case .zone(let id): try await sdn.deleteZone(id)
            case .vnet(let id): try await sdn.deleteVNet(id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// New, Changed or Deleted, for objects with pending changes.
struct SDNStateBadge: View {
    let state: SDNObject.State?

    var body: some View {
        if let state {
            Text(title(state))
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color(state).opacity(0.15), in: .capsule)
                .foregroundStyle(color(state))
        }
    }

    private func title(_ state: SDNObject.State) -> LocalizedStringKey {
        switch state {
        case .new: "New"
        case .changed: "Changed"
        case .deleted: "Deleted"
        }
    }

    private func color(_ state: SDNObject.State) -> Color {
        switch state {
        case .new: .green
        case .changed: .orange
        case .deleted: .red
        }
    }
}

private struct ZoneRow: View {
    let zone: SDNObject
    let status: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.dashed")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(zone.id)
                        .font(.body.weight(.medium))
                        .strikethrough(zone.state == .deleted)
                    SDNStateBadge(state: zone.state)
                }
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let status, zone.state != .new {
                StatusDot(color: status == "available" ? .green : .orange)
                    .accessibilityLabel(status)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        let type = SDNZoneType(rawValue: zone.type)?.title ?? zone.type.uppercased()
        return [type, zone["bridge"], zone["dhcp"] == "dnsmasq" ? String(localized: "DHCP") : nil, zone["mtu"].map { "MTU \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private struct VNetRow: View {
    let vnet: SDNObject
    let subnets: [SDNObject]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(vnet.id)
                        .font(.body.weight(.medium))
                        .strikethrough(vnet.state == .deleted)
                    if let alias = vnet["alias"] {
                        Text(alias).foregroundStyle(.secondary).lineLimit(1)
                    }
                    SDNStateBadge(state: vnet.state)
                }
                Text(([vnet.zone.map { String(localized: "Zone \($0)") }, vnet["tag"].map { String(localized: "Tag \($0)") }]
                      + subnets.filter { $0.state != .deleted }.map { $0["cidr"] }).compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Zone

struct SDNZoneEditor: View {
    let sdn: SDNSettings
    let zone: SDNObject?
    let original: SDNZoneDraft
    @State private var draft: SDNZoneDraft
    @State private var bridges: [String] = []
    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(sdn: SDNSettings, zone: SDNObject?) {
        self.sdn = sdn
        self.zone = zone
        let draft = zone.map(SDNZoneDraft.init) ?? SDNZoneDraft()
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { zone == nil }
    private var nodes: [String] { sdn.connection.snapshot?.nodes.map(\.name) ?? [] }

    private var errors: [String: String] {
        (showsProblems ? draft.problems(isNew: isNew) : [:]).merging(fieldErrors) { _, server in server }
    }

    var body: some View {
        Form {
            if !sdn.canModify {
                Section {
                    Label("Read only. Changing SDN needs the SDN.Allocate privilege.", systemImage: "lock.fill")
                        .font(.subheadline)
                }
            }
            Group {
                Section {
                    if isNew {
                        LabeledTextField(title: "ID", prompt: "zone1", text: $draft.id, identifier: "sdn.zone.id")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        FieldError(message: errors["zone"])
                        Picker("Type", selection: $draft.type) {
                            ForEach(SDNZoneType.allCases) { Text($0.title).tag($0) }
                        }
                        .accessibilityIdentifier("sdn.zone.type")
                    } else {
                        LabeledContent("Type", value: draft.type.title)
                    }
                } footer: {
                    if isNew { Text(Self.typeDescription(draft.type)) }
                }
                typeSection
                Section {
                    LabeledTextField(title: "MTU", prompt: "Auto", text: $draft.mtu, keyboard: .numberPad, identifier: "sdn.zone.mtu")
                    FieldError(message: errors["mtu"])
                    if nodes.count > 1 {
                        NavigationLink {
                            Form {
                                Section {
                                    ForEach(nodes, id: \.self) { node in
                                        Toggle(node, isOn: Binding(get: { draft.nodes.contains(node) }, set: { on in
                                            if on { draft.nodes.insert(node) } else { draft.nodes.remove(node) }
                                        }))
                                    }
                                } footer: {
                                    Text("None selected means all nodes.")
                                }
                            }
                            .navigationTitle("Nodes")
                        } label: {
                            LabeledContent("Nodes", value: draft.nodes.isEmpty ? String(localized: "All") : draft.nodes.sorted().joined(separator: ", "))
                        }
                    }
                    Picker("IPAM", selection: $draft.ipam) {
                        Text("None").tag("")
                        ForEach(sdn.ipams) { Text($0.id).tag($0.id) }
                        if !draft.ipam.isEmpty, !sdn.ipams.contains(where: { $0.id == draft.ipam }) { Text(draft.ipam).tag(draft.ipam) }
                    }
                    .accessibilityIdentifier("sdn.zone.ipam")
                    FieldError(message: errors["ipam"])
                } footer: {
                    Text("The IPAM keeps track of the addresses of the zone's subnets. Changing it is not possible while the zone has subnets.")
                }
                dnsSection
            }
            .disabled(!sdn.canModify)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isNew ? "New Zone" : draft.id)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            if sdn.canModify {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(!isNew && draft.changes(from: original).isEmpty)
                        .accessibilityIdentifier("save")
                }
            }
        }
        .task(id: draft.type) {
            guard draft.type == .vlan || draft.type == .qinq, bridges.isEmpty, let node = sdn.connection.snapshot?.nodes.first(where: \.isOnline)?.name else { return }
            let configuration = try? await sdn.connection.send(PVE.network(node: node))
            bridges = (configuration?.interfaces ?? []).filter { $0.type == "bridge" || $0.type == "OVSBridge" }.map(\.name).sorted()
            if draft.bridge.isEmpty { draft.bridge = bridges.first ?? "" }
        }
    }

    @ViewBuilder
    private var typeSection: some View {
        switch draft.type {
        case .simple:
            Section {
                Toggle("Automatic DHCP", isOn: $draft.automaticDHCP)
                    .accessibilityIdentifier("sdn.zone.dhcp")
                FieldError(message: errors["dhcp"])
            } footer: {
                Text("Hands out addresses of the subnets' DHCP ranges with dnsmasq, which has to be installed on every node.")
            }
        case .vlan, .qinq:
            Section {
                Picker("Bridge", selection: $draft.bridge) {
                    if draft.bridge.isEmpty { Text("Choose").tag("") }
                    ForEach(bridges, id: \.self) { Text($0).tag($0) }
                    if !draft.bridge.isEmpty, !bridges.contains(draft.bridge) { Text(draft.bridge).tag(draft.bridge) }
                }
                .accessibilityIdentifier("sdn.zone.bridge")
                FieldError(message: errors["bridge"])
                if draft.type == .qinq {
                    LabeledTextField(title: "Service VLAN", prompt: "100", text: $draft.serviceVLAN, keyboard: .numberPad, identifier: "sdn.zone.tag")
                    FieldError(message: errors["tag"])
                    Picker("Service VLAN Protocol", selection: $draft.vlanProtocol) {
                        Text("Default (802.1q)").tag("")
                        Text(verbatim: "802.1q").tag("802.1q")
                        Text(verbatim: "802.1ad").tag("802.1ad")
                    }
                }
            } footer: {
                Text(draft.type == .vlan
                    ? "VNets of the zone tag their traffic with their own VLAN on this bridge."
                    : "VNets of the zone stack their VLAN inside the service VLAN on this bridge.")
            }
        case .vxlan:
            Section {
                LabeledTextField(title: "Peers", prompt: "10.0.0.1, 10.0.0.2", text: $draft.peers, keyboard: .numbersAndPunctuation, identifier: "sdn.zone.peers")
                FieldError(message: errors["peers"])
                LabeledTextField(title: "UDP Port", prompt: "4789", text: $draft.vxlanPort, keyboard: .numberPad)
                FieldError(message: errors["vxlan-port"])
            } footer: {
                Text("The addresses of every node in the zone, including this one. VXLAN adds 50 bytes to each packet, so lower the MTU to 1450 or less.")
            }
        }
    }

    @ViewBuilder
    private var dnsSection: some View {
        if !sdn.dnsServers.isEmpty || !draft.dns.isEmpty || !draft.dnsZone.isEmpty {
            Section {
                Picker("DNS Server", selection: $draft.dns) {
                    Text("None").tag("")
                    ForEach(sdn.dnsServers) { Text($0.id).tag($0.id) }
                    if !draft.dns.isEmpty, !sdn.dnsServers.contains(where: { $0.id == draft.dns }) { Text(draft.dns).tag(draft.dns) }
                }
                Picker("Reverse DNS Server", selection: $draft.reverseDNS) {
                    Text("None").tag("")
                    ForEach(sdn.dnsServers) { Text($0.id).tag($0.id) }
                    if !draft.reverseDNS.isEmpty, !sdn.dnsServers.contains(where: { $0.id == draft.reverseDNS }) { Text(draft.reverseDNS).tag(draft.reverseDNS) }
                }
                LabeledTextField(title: "DNS Zone", prompt: "example.com", text: $draft.dnsZone, keyboard: .URL)
                    .textInputAutocapitalization(.never)
            } header: {
                Text("DNS")
            } footer: {
                Text("Guests get records in this zone on the DNS server.")
            }
        }
    }

    private static func typeDescription(_ type: SDNZoneType) -> LocalizedStringKey {
        switch type {
        case .simple: "An isolated bridge on each node. Subnets add routing, SNAT and optionally DHCP."
        case .vlan: "Separates VNets by VLAN tags on an existing bridge, which needs to reach the other nodes."
        case .qinq: "Like VLAN, with every VNet inside a shared outer service VLAN."
        case .vxlan: "Connects nodes over UDP tunnels, so VNets span nodes without VLANs on the switches."
        }
    }

    private func save() async {
        showsProblems = true
        fieldErrors = [:]
        guard draft.problems(isNew: isNew).isEmpty else {
            errorMessage = String(localized: "Check the highlighted fields.")
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if isNew {
                try await sdn.createZone(draft)
            } else {
                try await sdn.updateZone(draft.id, draft.changes(from: original))
            }
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - VNet

struct SDNVNetDetailView: View {
    let sdn: SDNSettings
    let vnetID: String
    @State private var addsSubnet = false
    @State private var deleting: SDNObject?
    @State private var errorMessage: String?

    private var vnet: SDNObject? { sdn.vnets?.first { $0.id == vnetID } }

    var body: some View {
        List {
            if let vnet {
                Section {
                    NavigationLink {
                        SDNVNetEditor(sdn: sdn, vnet: vnet)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Settings")
                                SDNStateBadge(state: vnet.state)
                            }
                            Text([vnet["alias"], vnet.zone.map { String(localized: "Zone \($0)") }, vnet["tag"].map { String(localized: "Tag \($0)") },
                                  vnet["vlanaware"] == "1" ? String(localized: "VLAN aware") : nil, vnet["isolate-ports"] == "1" ? String(localized: "Isolated ports") : nil]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("sdn.vnet.settings")
                    NavigationLink {
                        FirewallView(connection: sdn.connection, scope: .vnet(vnetID, zone: vnet.zone ?? ""))
                    } label: {
                        Label("Firewall", systemImage: "flame")
                    }
                    .accessibilityIdentifier("sdn.vnet.firewall")
                }
                Section {
                    let subnets = sdn.subnets[vnetID] ?? []
                    if subnets.isEmpty {
                        Text("No subnets").foregroundStyle(.secondary)
                    }
                    ForEach(subnets) { subnet in
                        NavigationLink {
                            SDNSubnetEditor(sdn: sdn, vnet: vnetID, subnet: subnet)
                        } label: {
                            SubnetRow(subnet: subnet)
                        }
                        .disabled(subnet.state == .deleted)
                        .accessibilityIdentifier("sdn.subnet.\(subnet["cidr"] ?? subnet.id)")
                        .swipeActions {
                            if sdn.canModify, subnet.state != .deleted {
                                Button("Delete", systemImage: "trash") { deleting = subnet }
                                    .tint(.red)
                            }
                        }
                    }
                    Button("Add Subnet", systemImage: "plus") { addsSubnet = true }
                        .disabled(!sdn.canModify || vnet.state == .deleted)
                        .accessibilityIdentifier("sdn.subnet.add")
                } header: {
                    Text("Subnets")
                } footer: {
                    Text("In simple zones the gateway is set on the VNet's bridge, SNAT gives guests internet access through the node, and DHCP ranges are handed out when the zone has automatic DHCP.")
                }
            }
        }
        .navigationTitle(vnetID)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await sdn.load() }
        .sheet(isPresented: $addsSubnet) {
            NavigationStack { SDNSubnetEditor(sdn: sdn, vnet: vnetID, subnet: nil) }
        }
        .confirmationDialog("Delete the subnet \(deleting?["cidr"] ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { subnet in
            Button("Delete", role: .destructive) { Task { await delete(subnet) } }
        } message: { _ in
            Text("Its addresses leave the IPAM right away, even before Apply.")
        }
        .alert("SDN Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func delete(_ subnet: SDNObject) async {
        do {
            try await sdn.deleteSubnet(vnet: vnetID, id: subnet.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SubnetRow: View {
    let subnet: SDNObject

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(subnet["cidr"] ?? subnet.id)
                    .font(.body.monospaced())
                    .strikethrough(subnet.state == .deleted)
                SDNStateBadge(state: subnet.state)
            }
            Text(([subnet["gateway"].map { String(localized: "Gateway \($0)") }, subnet["snat"] == "1" ? String(localized: "SNAT") : nil]
                  + subnet.ranges.map { "DHCP \($0.start)–\($0.end)" }).compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SDNVNetEditor: View {
    let sdn: SDNSettings
    let vnet: SDNObject?
    let original: SDNVNetDraft
    @State private var draft: SDNVNetDraft
    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(sdn: SDNSettings, vnet: SDNObject?) {
        self.sdn = sdn
        self.vnet = vnet
        var draft = vnet.map(SDNVNetDraft.init) ?? SDNVNetDraft()
        if vnet == nil { draft.zone = sdn.zones?.first { $0.state != .deleted }?.id ?? "" }
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { vnet == nil }
    private var zoneType: SDNZoneType? { sdn.zoneType(draft.zone) }

    private var errors: [String: String] {
        (showsProblems ? draft.problems(isNew: isNew, zoneType: zoneType) : [:]).merging(fieldErrors) { _, server in server }
    }

    var body: some View {
        Form {
            Group {
                Section {
                    if isNew {
                        LabeledTextField(title: "Name", prompt: "vnet1", text: $draft.id, identifier: "sdn.vnet.id")
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        FieldError(message: errors["vnet"])
                    }
                    LabeledTextField(title: "Alias", prompt: "None", text: $draft.alias, identifier: "sdn.vnet.alias")
                    FieldError(message: errors["alias"])
                    Picker("Zone", selection: $draft.zone) {
                        if draft.zone.isEmpty { Text("Choose").tag("") }
                        ForEach(sdn.zones?.filter { $0.state != .deleted } ?? []) { zone in
                            Text("\(zone.id) (\(SDNZoneType(rawValue: zone.type)?.title ?? zone.type))").tag(zone.id)
                        }
                    }
                    .accessibilityIdentifier("sdn.vnet.zone")
                    FieldError(message: errors["zone"])
                    if zoneType?.allowsVNetTag != false {
                        LabeledTextField(title: zoneType == .vxlan ? "VXLAN ID" : "VLAN Tag", prompt: zoneType?.requiresVNetTag == true ? "Required" : "None",
                                         text: $draft.tag, keyboard: .numberPad, identifier: "sdn.vnet.tag")
                        FieldError(message: errors["tag"])
                    }
                } footer: {
                    Text("The name is the bridge guests are attached to, at most 8 letters and digits. The alias is only a description.")
                }
                Section {
                    Toggle("VLAN Aware", isOn: $draft.isVLANAware)
                    Toggle("Isolate Ports", isOn: $draft.isolatesPorts)
                } footer: {
                    Text("VLAN aware lets guests tag their own traffic on the VNet. Isolated ports keep guests on the VNet from reaching each other; they only reach the network beyond it.")
                }
            }
            .disabled(!sdn.canModify)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isNew ? "New VNet" : draft.id)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            if sdn.canModify {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(!isNew && draft.changes(from: original, zoneType: zoneType).isEmpty)
                        .accessibilityIdentifier("save")
                }
            }
        }
    }

    private func save() async {
        showsProblems = true
        fieldErrors = [:]
        guard draft.problems(isNew: isNew, zoneType: zoneType).isEmpty else {
            errorMessage = String(localized: "Check the highlighted fields.")
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if isNew {
                try await sdn.createVNet(draft)
            } else {
                try await sdn.updateVNet(draft.id, draft.changes(from: original, zoneType: zoneType))
            }
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Subnet

struct SDNSubnetEditor: View {
    let sdn: SDNSettings
    let vnet: String
    let subnet: SDNObject?
    let original: SDNSubnetDraft
    @State private var draft: SDNSubnetDraft
    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    init(sdn: SDNSettings, vnet: String, subnet: SDNObject?) {
        self.sdn = sdn
        self.vnet = vnet
        self.subnet = subnet
        let draft = subnet.map(SDNSubnetDraft.init) ?? SDNSubnetDraft()
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { subnet == nil }

    private var errors: [String: String] {
        (showsProblems ? draft.problems(isNew: isNew) : [:]).merging(fieldErrors) { _, server in server }
    }

    private var zoneHasDHCP: Bool {
        let zone = sdn.vnets?.first { $0.id == vnet }?.zone
        return sdn.zones?.first { $0.id == zone }?["dhcp"] != nil
    }

    var body: some View {
        Form {
            Group {
                Section {
                    if isNew {
                        LabeledTextField(title: "Subnet", prompt: "10.0.0.0/24", text: $draft.cidr, keyboard: .numbersAndPunctuation, identifier: "sdn.subnet.cidr")
                        FieldError(message: errors["subnet"])
                    } else {
                        LabeledContent("Subnet", value: draft.cidr)
                    }
                    LabeledTextField(title: "Gateway", prompt: "10.0.0.1", text: $draft.gateway, keyboard: .numbersAndPunctuation, identifier: "sdn.subnet.gateway")
                    FieldError(message: errors["gateway"])
                    Toggle("SNAT", isOn: $draft.snat)
                        .accessibilityIdentifier("sdn.subnet.snat")
                    LabeledTextField(title: "DNS Zone Prefix", prompt: "None", text: $draft.dnsZonePrefix)
                        .textInputAutocapitalization(.never)
                    FieldError(message: errors["dnszoneprefix"])
                } footer: {
                    Text("SNAT hides the subnet behind the node's address for outgoing traffic. The DNS zone prefix is added to the zone's DNS zone for the guests' records.")
                }
                Section {
                    ForEach($draft.ranges.indices, id: \.self) { index in
                        HStack {
                            TextField("Start", text: $draft.ranges[index].start)
                                .keyboardType(.numbersAndPunctuation)
                                .accessibilityIdentifier("sdn.range.\(index).start")
                            Text(verbatim: "–").foregroundStyle(.secondary)
                            TextField("End", text: $draft.ranges[index].end)
                                .keyboardType(.numbersAndPunctuation)
                                .accessibilityIdentifier("sdn.range.\(index).end")
                        }
                        .font(.body.monospaced())
                    }
                    .onDelete { draft.ranges.remove(atOffsets: $0) }
                    Button("Add Range", systemImage: "plus") { draft.ranges.append(SDNDHCPRange(start: "", end: "")) }
                        .accessibilityIdentifier("sdn.range.add")
                    FieldError(message: errors["dhcp-range"])
                    LabeledTextField(title: "DNS Server", prompt: "Gateway", text: $draft.dhcpDNSServer, keyboard: .numbersAndPunctuation)
                    FieldError(message: errors["dhcp-dns-server"])
                } header: {
                    Text("DHCP")
                } footer: {
                    Text(zoneHasDHCP
                        ? "Guests on the VNet get addresses from these ranges. The DNS server is announced to them."
                        : "Ranges are only handed out when the zone has automatic DHCP.")
                }
            }
            .disabled(!sdn.canModify)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(isNew ? "New Subnet" : draft.cidr)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            if sdn.canModify {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await save() } }
                        .disabled(!isNew && draft.changes(from: original).isEmpty)
                        .accessibilityIdentifier("save")
                }
            }
        }
    }

    private func save() async {
        showsProblems = true
        fieldErrors = [:]
        guard draft.problems(isNew: isNew).isEmpty else {
            errorMessage = String(localized: "Check the highlighted fields.")
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if let subnet {
                try await sdn.updateSubnet(vnet: vnet, id: subnet.id, draft.changes(from: original))
            } else {
                try await sdn.createSubnet(vnet: vnet, draft)
            }
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - IPAM

/// Addresses the built-in IPAM handed out: gateways and guests' network devices.
private struct IPAMView: View {
    let sdn: SDNSettings
    let ipam: String
    @State private var entries: [IPAMEntry]?
    @State private var errorMessage: String?

    var body: some View {
        List {
            let byVNet = Dictionary(grouping: entries ?? []) { $0.vnet ?? "" }
            ForEach(byVNet.keys.sorted(), id: \.self) { vnet in
                Section(vnet) {
                    ForEach(byVNet[vnet]!.sorted { $0.ip.localizedStandardCompare($1.ip) == .orderedAscending }) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.ip).font(.body.monospaced())
                                if entry.isGateway { AccessBadge(text: "Gateway") }
                            }
                            let details = [entry.vmid.map { "\($0)" }, entry.hostname, entry.mac].compactMap { $0 }
                            if !details.isEmpty {
                                Text(details.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .overlay {
            if let errorMessage {
                ContentUnavailableView("Cannot Load the IPAM", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if entries == nil {
                ProgressView()
            } else if entries?.isEmpty == true {
                ContentUnavailableView("No Addresses", systemImage: "list.number", description: Text("Gateways and guests on VNets with subnets show here."))
            }
        }
        .navigationTitle("IPAM \(ipam)")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            entries = try await sdn.ipamEntries(ipam)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
