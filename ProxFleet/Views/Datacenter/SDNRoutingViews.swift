import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

// The routing side of SDN: controllers, fabrics, route maps and prefix lists. Like zones and VNets, changes stay
// pending until Apply on the SDN screen.

/// A form for an SDN object: checks the app's own problems first, shows the server's field errors, and closes
/// after saving.
struct SDNEditorForm<Content: View>: View {
    let title: String
    let sdn: SDNSettings
    let isNew: Bool
    let hasChanges: Bool
    let problems: [String: String]
    let save: () async throws(ConfigUpdateError) -> Void
    @ViewBuilder let content: (_ errors: [String: String]) -> Content

    @State private var isSaving = false
    @State private var showsProblems = false
    @State private var errorMessage: String?
    @State private var fieldErrors: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    private var errors: [String: String] {
        (showsProblems ? problems : [:]).merging(fieldErrors) { _, server in server }
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
                content(errors)
            }
            .disabled(!sdn.canModify)
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(title)
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
                    ProgressButton(isNew ? "Add" : "Save", isWorking: isSaving) { Task { await run() } }
                        .disabled(!isNew && !hasChanges)
                        .accessibilityIdentifier("save")
                }
            }
        }
    }

    private func run() async {
        showsProblems = true
        fieldErrors = [:]
        guard problems.isEmpty else {
            errorMessage = String(localized: "Check the highlighted fields.")
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await save()
            dismiss()
        } catch .invalid(let message, let fields) {
            fieldErrors = fields
            errorMessage = message ?? String(localized: "Check the highlighted fields.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A list of SDN objects with pending badges, swipe to delete, an Add button and a confirmation.
private struct SDNObjectRow: View {
    let title: String
    let subtitle: String
    let state: SDNObject.State?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.body.weight(.medium))
                    .strikethrough(state == .deleted)
                SDNStateBadge(state: state)
            }
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Runs an SDN change and shows its error in an alert.
private struct SDNErrorAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert("SDN Error", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message ?? "")
        }
    }
}

private extension View {
    func sdnErrorAlert(_ message: Binding<String?>) -> some View { modifier(SDNErrorAlert(message: message)) }
}

private func pendingFooter(_ sdn: SDNSettings) -> Text? {
    sdn.hasPendingChanges ? Text("Changes take effect when you apply them on the SDN screen.") : nil
}

/// A picker of names, such as route maps or prefix lists, with None and the current value kept.
private struct NamePicker: View {
    let title: LocalizedStringKey
    let names: [String]
    @Binding var selection: String
    var identifier: String?

    var body: some View {
        Picker(title, selection: $selection) {
            Text("None").tag("")
            ForEach(names, id: \.self) { Text($0).tag($0) }
            if !selection.isEmpty, !names.contains(selection) { Text(selection).tag(selection) }
        }
        .accessibilityIdentifier(identifier ?? "")
    }
}

// MARK: - Controllers

struct SDNControllersView: View {
    let sdn: SDNSettings
    @State private var creating: SDNControllerType?
    @State private var deleting: SDNObject?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if sdn.controllers.isEmpty {
                    Text("No controllers").foregroundStyle(.secondary)
                }
                ForEach(sdn.controllers) { controller in
                    NavigationLink {
                        SDNControllerEditor(sdn: sdn, controller: controller)
                    } label: {
                        SDNObjectRow(title: controller.id, subtitle: summary(controller), state: controller.state)
                    }
                    .disabled(controller.state == .deleted)
                    .accessibilityIdentifier("sdn.controller.\(controller.id)")
                    .swipeActions {
                        if sdn.canModify, controller.state != .deleted {
                            Button("Delete", systemImage: "trash") { deleting = controller }
                                .tint(.red)
                        }
                    }
                }
            } footer: {
                Text("An EVPN controller runs BGP between the nodes for EVPN zones; there can be one. BGP and IS-IS controllers add a node's own sessions to the outside network or an underlay.")
            }
        }
        .navigationTitle("Controllers")
        .refreshable { await sdn.load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    ForEach(SDNControllerType.allCases) { type in
                        Button(type.title) { creating = type }
                            .accessibilityIdentifier("sdn.add.controller.\(type.rawValue)")
                    }
                }
                .disabled(!sdn.canModify)
                .accessibilityIdentifier("sdn.add.controller")
            }
        }
        .sheet(item: $creating) { type in
            NavigationStack { SDNControllerEditor(sdn: sdn, controller: nil, type: type) }
        }
        .confirmationDialog("Delete the controller \(deleting?.id ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { controller in
            Button("Delete", role: .destructive) {
                Task {
                    do { try await sdn.deleteController(controller.id) } catch { errorMessage = error.localizedDescription }
                }
            }
        } message: { _ in
            Text("The deletion takes effect on Apply. Controllers used by a zone cannot be deleted.")
        }
        .sdnErrorAlert($errorMessage)
    }

    private func summary(_ controller: SDNObject) -> String {
        let type = SDNControllerType(rawValue: controller.type)?.title ?? controller.type.uppercased()
        return [type, controller["node"], controller["asn"].map { "AS \($0)" }, controller["peers"], controller["fabric"], controller["isis-domain"]]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct SDNControllerEditor: View {
    let sdn: SDNSettings
    let controller: SDNObject?
    let original: SDNControllerDraft
    @State private var draft: SDNControllerDraft

    init(sdn: SDNSettings, controller: SDNObject?, type: SDNControllerType = .evpn) {
        self.sdn = sdn
        self.controller = controller
        var draft = controller.map(SDNControllerDraft.init) ?? SDNControllerDraft(type: type)
        if controller == nil, type.isPerNode { draft.node = sdn.connection.snapshot?.nodes.first?.name ?? "" }
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { controller == nil }
    private var nodes: [String] { sdn.connection.snapshot?.nodes.map(\.name) ?? [] }

    var body: some View {
        SDNEditorForm(title: isNew ? String(localized: "New \(draft.type.title) Controller") : draft.resolvedID, sdn: sdn, isNew: isNew,
                      hasChanges: !draft.changes(from: original).isEmpty, problems: draft.problems(isNew: isNew)) { () throws(ConfigUpdateError) in
            if isNew {
                try await sdn.createController(draft)
            } else {
                try await sdn.updateController(draft.resolvedID, draft.changes(from: original))
            }
        } content: { errors in
            Section {
                if draft.type == .evpn {
                    if isNew {
                        LabeledTextField(title: "ID", prompt: "evpn1", text: $draft.id, identifier: "sdn.controller.id")
                        FieldError(message: errors["controller"])
                    }
                } else if isNew {
                    Picker("Node", selection: $draft.node) {
                        ForEach(nodes, id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("sdn.controller.node")
                    FieldError(message: errors["node"])
                } else {
                    LabeledContent("Node", value: draft.node)
                }
                if draft.type != .isis {
                    LabeledTextField(title: "ASN", prompt: "65000", text: $draft.asn, keyboard: .numberPad, identifier: "sdn.controller.asn")
                    FieldError(message: errors["asn"])
                    LabeledTextField(title: "Peers", prompt: draft.type == .evpn ? "10.0.0.1, 10.0.0.2" : "10.0.0.254", text: $draft.peers,
                                     keyboard: .numbersAndPunctuation, identifier: "sdn.controller.peers")
                    FieldError(message: errors["peers"])
                }
                if draft.type == .evpn {
                    NamePicker(title: "Fabric", names: sdn.fabrics.filter { $0.state != .deleted }.map(\.id), selection: $draft.fabric)
                }
                if draft.type == .bgp {
                    Toggle("eBGP", isOn: $draft.ebgp)
                }
            } footer: {
                switch draft.type {
                case .evpn: Text("The nodes' own addresses as peers, or a fabric between them. All nodes share the AS number unless BGP controllers give them their own.")
                case .bgp: Text("BGP sessions of this node to routers outside the cluster, named bgp\(draft.node.isEmpty ? "<node>" : draft.node). eBGP is for peers in another AS.")
                case .isis: Text("IS-IS on this node's interfaces as underlay for EVPN, named isis\(draft.node.isEmpty ? "<node>" : draft.node).")
                }
            }
            if draft.type == .isis {
                Section("IS-IS") {
                    LabeledTextField(title: "Domain", prompt: "default", text: $draft.isisDomain, identifier: "sdn.controller.isisdomain")
                    FieldError(message: errors["isis-domain"])
                    LabeledTextField(title: "Network Entity Title", prompt: "49.0001.1921.6800.1001.00", text: $draft.isisNet, keyboard: .numbersAndPunctuation,
                                     identifier: "sdn.controller.isisnet")
                    FieldError(message: errors["isis-net"])
                    LabeledTextField(title: "Interfaces", prompt: "ens19, ens20", text: $draft.isisInterfaces, identifier: "sdn.controller.isisifaces")
                    FieldError(message: errors["isis-ifaces"])
                }
            }
            Section {
                if draft.type != .isis {
                    NamePicker(title: "Incoming Route Map", names: sdn.routeMapNames, selection: $draft.routeMapIn)
                    NamePicker(title: "Outgoing Route Map", names: sdn.routeMapNames, selection: $draft.routeMapOut)
                    LabeledTextField(title: "eBGP Multihop", prompt: "None", text: $draft.ebgpMultihop, keyboard: .numberPad)
                    FieldError(message: errors["ebgp-multihop"])
                }
                if draft.type == .evpn {
                    LabeledTextField(title: "Peer Group Name", prompt: "VTEP", text: $draft.peerGroupName)
                    Picker("BGP Mode", selection: $draft.bgpMode) {
                        Text("Automatic").tag("")
                        Text(verbatim: "eBGP").tag("external")
                        Text(verbatim: "iBGP").tag("internal")
                    }
                    if nodes.count > 1 {
                        NodeSetPicker(title: "Nodes", nodes: nodes, selection: $draft.nodes, emptyMeaning: "All")
                    }
                }
                if draft.type != .evpn {
                    LabeledTextField(title: "Loopback Interface", prompt: "None", text: $draft.loopback)
                }
                if draft.type == .bgp {
                    Toggle("Multipath AS-Path Relax", isOn: $draft.multipathRelax)
                }
            } header: {
                Text("Advanced")
            } footer: {
                pendingFooter(sdn)
            }
        }
    }
}

// MARK: - Fabrics

struct SDNFabricsView: View {
    let sdn: SDNSettings
    @State private var creating: SDNFabricProtocol?
    @State private var deleting: SDNObject?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if sdn.fabrics.isEmpty {
                Section {
                    Text("No fabrics").foregroundStyle(.secondary)
                }
            }
            ForEach(sdn.fabrics) { fabric in
                Section {
                    NavigationLink {
                        SDNFabricView(sdn: sdn, fabricID: fabric.id)
                    } label: {
                        SDNObjectRow(title: fabric.id, subtitle: summary(fabric), state: fabric.state)
                    }
                    .disabled(fabric.state == .deleted)
                    .accessibilityIdentifier("sdn.fabric.\(fabric.id)")
                    .swipeActions {
                        if sdn.canModify, fabric.state != .deleted {
                            Button("Delete", systemImage: "trash") { deleting = fabric }
                                .tint(.red)
                        }
                    }
                }
            }
            Section {
            } footer: {
                Text("A fabric connects the nodes over routed links: each node gets an address from the fabric's prefix, and the fabric routes between them. VXLAN and EVPN zones and the EVPN controller can use it instead of a list of peers. WireGuard fabrics are set up in the web interface.")
            }
        }
        .navigationTitle("Fabrics")
        .refreshable { await sdn.load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    ForEach(SDNFabricProtocol.allCases) { type in
                        Button(type.title) { creating = type }
                            .accessibilityIdentifier("sdn.add.fabric.\(type.rawValue)")
                    }
                }
                .disabled(!sdn.canModify)
                .accessibilityIdentifier("sdn.add.fabric")
            }
        }
        .sheet(item: $creating) { type in
            NavigationStack { SDNFabricEditor(sdn: sdn, fabric: nil, protocol: type) }
        }
        .confirmationDialog("Delete the fabric \(deleting?.id ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { fabric in
            Button("Delete", role: .destructive) {
                Task {
                    do { try await sdn.deleteFabric(fabric.id) } catch { errorMessage = error.localizedDescription }
                }
            }
        } message: { _ in
            Text("The deletion takes effect on Apply. Remove the fabric's nodes first.")
        }
        .sdnErrorAlert($errorMessage)
    }

    private func summary(_ fabric: SDNObject) -> String {
        let type = SDNFabricProtocol(rawValue: fabric["protocol"] ?? "")?.title ?? fabric["protocol"] ?? ""
        let nodes = sdn.nodes(ofFabric: fabric.id).filter { $0.state != .deleted }.map(\.id)
        return ([type, fabric["ip_prefix"], fabric["ip6_prefix"]] + [nodes.isEmpty ? String(localized: "No nodes") : nodes.joined(separator: ", ")])
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// A fabric's settings and its nodes.
private struct SDNFabricView: View {
    let sdn: SDNSettings
    let fabricID: String
    @State private var addsNode = false
    @State private var removing: SDNObject?
    @State private var errorMessage: String?

    private var fabric: SDNObject? { sdn.fabrics.first { $0.id == fabricID } }

    var body: some View {
        List {
            if let fabric {
                let draft = SDNFabricDraft(fabric)
                Section {
                    NavigationLink {
                        SDNFabricEditor(sdn: sdn, fabric: fabric, protocol: draft.protocolType)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Settings")
                                SDNStateBadge(state: fabric.state)
                            }
                            Text([draft.protocolType.title, fabric["ip_prefix"], fabric["ip6_prefix"], fabric["area"].map { String(localized: "Area \($0)") },
                                  fabric["route_filter"].map { String(localized: "Filter \($0)") }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("sdn.fabric.settings")
                }
                Section {
                    let nodes = sdn.nodes(ofFabric: fabricID)
                    if nodes.isEmpty {
                        Text("No nodes").foregroundStyle(.secondary)
                    }
                    ForEach(nodes) { node in
                        NavigationLink {
                            SDNFabricNodeEditor(sdn: sdn, fabric: fabric, node: node)
                        } label: {
                            let nodeDraft = SDNFabricNodeDraft(node)
                            SDNObjectRow(title: node.id, subtitle: ([nodeDraft.ip, nodeDraft.ip6, nodeDraft.asn.isEmpty ? "" : "AS \(nodeDraft.asn)"]
                                                                   + nodeDraft.interfaces.map(\.name)).filter { !$0.isEmpty }.joined(separator: " · "),
                                         state: node.state)
                        }
                        .disabled(node.state == .deleted)
                        .accessibilityIdentifier("sdn.fabricnode.\(node.id)")
                        .swipeActions {
                            if sdn.canModify, node.state != .deleted {
                                Button("Remove", systemImage: "trash") { removing = node }
                                    .tint(.red)
                            }
                        }
                    }
                    let members = Set(nodes.map(\.id))
                    if sdn.connection.snapshot?.nodes.contains(where: { !members.contains($0.name) }) != false {
                        Button("Add Node", systemImage: "plus") { addsNode = true }
                            .disabled(!sdn.canModify || fabric.state == .deleted)
                            .accessibilityIdentifier("sdn.fabricnode.add")
                    }
                } header: {
                    Text("Nodes")
                } footer: {
                    Text("Each node takes part with the interfaces that lead to the other nodes. Those interfaces should not have addresses in the node's network settings; set them here instead.")
                }
            }
        }
        .navigationTitle(fabricID)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await sdn.load() }
        .sheet(isPresented: $addsNode) {
            if let fabric { NavigationStack { SDNFabricNodeEditor(sdn: sdn, fabric: fabric, node: nil) } }
        }
        .confirmationDialog("Remove \(removing?.id ?? "") from the fabric?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { node in
            Button("Remove", role: .destructive) {
                Task {
                    do { try await sdn.removeFabricNode(fabric: fabricID, node: node.id) } catch { errorMessage = error.localizedDescription }
                }
            }
        } message: { _ in
            Text("The node leaves the fabric on Apply.")
        }
        .sdnErrorAlert($errorMessage)
    }
}

struct SDNFabricEditor: View {
    let sdn: SDNSettings
    let fabric: SDNObject?
    let original: SDNFabricDraft
    @State private var draft: SDNFabricDraft

    init(sdn: SDNSettings, fabric: SDNObject?, protocol protocolType: SDNFabricProtocol) {
        self.sdn = sdn
        self.fabric = fabric
        let draft = fabric.map(SDNFabricDraft.init) ?? SDNFabricDraft(protocol: protocolType)
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { fabric == nil }

    var body: some View {
        SDNEditorForm(title: isNew ? String(localized: "New \(draft.protocolType.title) Fabric") : draft.id, sdn: sdn, isNew: isNew,
                      hasChanges: !draft.changes(from: original).isEmpty, problems: draft.problems(isNew: isNew)) { () throws(ConfigUpdateError) in
            if isNew {
                try await sdn.createFabric(draft)
            } else {
                try await sdn.updateFabric(draft.id, protocol: draft.protocolType, draft.changes(from: original))
            }
        } content: { errors in
            Section {
                if isNew {
                    LabeledTextField(title: "Name", prompt: "fabric1", text: $draft.id, identifier: "sdn.fabric.id")
                    FieldError(message: errors["id"])
                }
                LabeledTextField(title: "IPv4 Prefix", prompt: "10.10.10.0/24", text: $draft.ipPrefix, keyboard: .numbersAndPunctuation, identifier: "sdn.fabric.prefix")
                FieldError(message: errors["ip_prefix"])
                if draft.protocolType.supportsIPv6 {
                    LabeledTextField(title: "IPv6 Prefix", prompt: "fd00:10::/64", text: $draft.ip6Prefix, keyboard: .numbersAndPunctuation)
                    FieldError(message: errors["ip6_prefix"])
                }
                if draft.protocolType == .ospf {
                    LabeledTextField(title: "Area", prompt: "0", text: $draft.area, keyboard: .numbersAndPunctuation)
                    FieldError(message: errors["area"])
                }
                NamePicker(title: "Route Filter", names: sdn.prefixListNames, selection: $draft.routeFilter, identifier: "sdn.fabric.filter")
            } footer: {
                Text("The nodes' router addresses lie in these prefixes. IPv6 fabrics need IPv6 forwarding on every node. The route filter is a prefix list for the routes the nodes install.")
            }
            switch draft.protocolType {
            case .openfabric:
                Section {
                    LabeledTextField(title: "Hello Interval", prompt: "3", text: $draft.helloInterval, keyboard: .numberPad)
                    FieldError(message: errors["hello_interval"])
                    LabeledTextField(title: "CSNP Interval", prompt: "10", text: $draft.csnpInterval, keyboard: .numberPad)
                    FieldError(message: errors["csnp_interval"])
                } header: {
                    Text("OpenFabric")
                } footer: {
                    Text("Seconds between hello and complete sequence number packets.")
                }
            case .ospf:
                EmptyView()
            case .bgp:
                Section {
                    Toggle("BFD", isOn: $draft.bfd)
                    NamePicker(title: "Incoming Route Map", names: sdn.routeMapNames, selection: $draft.routeMapIn)
                    NamePicker(title: "Outgoing Route Map", names: sdn.routeMapNames, selection: $draft.routeMapOut)
                } header: {
                    Text("BGP")
                } footer: {
                    Text("BFD notices failed links within a second.")
                }
            }
            if !draft.protocolType.redistributionSources.isEmpty {
                Section {
                    ForEach(draft.protocolType.redistributionSources, id: \.self) { source in
                        let index = draft.redistribution.firstIndex { $0.source == source }
                        Toggle(sourceTitle(source), isOn: Binding(get: { index != nil }, set: { on in
                            if on { draft.redistribution.append(SDNRedistribution(source: source)) } else { draft.redistribution.removeAll { $0.source == source } }
                        }))
                        .accessibilityIdentifier("sdn.fabric.redistribute.\(source)")
                        if let index {
                            NamePicker(title: "Route Map", names: sdn.routeMapNames, selection: $draft.redistribution[index].routeMap)
                                .padding(.leading)
                        }
                    }
                } header: {
                    Text("Route Redistribution")
                } footer: {
                    Text("Routes from these sources are announced in the fabric, optionally through a route map.")
                }
            }
        }
    }

    private func sourceTitle(_ source: String) -> LocalizedStringKey {
        switch source {
        case "bgp": "BGP"
        case "ospf": "OSPF"
        case "connected": "Connected"
        case "static": "Static"
        case "kernel": "Kernel"
        default: LocalizedStringKey(source)
        }
    }
}

/// Adds a node to a fabric or changes its addresses and interfaces. The interfaces come from the node's network
/// settings; ones with an address there cannot carry fabric addresses.
private struct SDNFabricNodeEditor: View {
    let sdn: SDNSettings
    let fabric: SDNObject
    let node: SDNObject?
    let original: SDNFabricNodeDraft
    @State private var draft: SDNFabricNodeDraft
    @State private var interfaces: [NetworkInterface]?

    init(sdn: SDNSettings, fabric: SDNObject, node: SDNObject?) {
        self.sdn = sdn
        self.fabric = fabric
        self.node = node
        var draft = node.map(SDNFabricNodeDraft.init) ?? SDNFabricNodeDraft(protocol: SDNFabricProtocol(rawValue: fabric["protocol"] ?? "") ?? .openfabric)
        if node == nil {
            let members = Set(sdn.nodes(ofFabric: fabric.id).map(\.id))
            draft.node = sdn.connection.snapshot?.nodes.map(\.name).first { !members.contains($0) } ?? ""
        }
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { node == nil }
    private var protocolType: SDNFabricProtocol { draft.protocolType }

    var body: some View {
        SDNEditorForm(title: isNew ? String(localized: "Add Node") : draft.node, sdn: sdn, isNew: isNew,
                      hasChanges: !draft.changes(from: original).isEmpty, problems: draft.problems(isNew: isNew)) { () throws(ConfigUpdateError) in
            if isNew {
                try await sdn.addFabricNode(fabric: fabric.id, draft)
            } else {
                try await sdn.updateFabricNode(fabric: fabric.id, node: draft.node, protocol: protocolType, draft.changes(from: original))
            }
        } content: { errors in
            Section {
                if isNew {
                    let members = Set(sdn.nodes(ofFabric: fabric.id).map(\.id))
                    Picker("Node", selection: $draft.node) {
                        ForEach((sdn.connection.snapshot?.nodes.map(\.name) ?? []).filter { !members.contains($0) }, id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("sdn.fabricnode.node")
                    FieldError(message: errors["node_id"])
                }
                if fabric["ip_prefix"] != nil || !draft.ip.isEmpty {
                    LabeledTextField(title: "IPv4", prompt: prefixHint(fabric["ip_prefix"]), text: $draft.ip, keyboard: .numbersAndPunctuation, identifier: "sdn.fabricnode.ip")
                    FieldError(message: errors["ip"])
                }
                if protocolType.supportsIPv6, fabric["ip6_prefix"] != nil || !draft.ip6.isEmpty {
                    LabeledTextField(title: "IPv6", prompt: prefixHint(fabric["ip6_prefix"]), text: $draft.ip6, keyboard: .numbersAndPunctuation)
                    FieldError(message: errors["ip6"])
                }
                if protocolType == .bgp {
                    LabeledTextField(title: "ASN", prompt: "65001", text: $draft.asn, keyboard: .numberPad, identifier: "sdn.fabricnode.asn")
                    FieldError(message: errors["asn"])
                }
            } footer: {
                Text("The node's router address in the fabric, from the fabric's prefix.")
            }
            Section {
                if let interfaces {
                    if interfaces.isEmpty { Text("No interfaces").foregroundStyle(.secondary) }
                    ForEach(interfaces) { interface in
                        interfaceRow(interface)
                    }
                } else {
                    ProgressView()
                }
                FieldError(message: errors["interfaces"])
            } header: {
                Text("Interfaces")
            } footer: {
                Text(protocolType == .bgp ? "BGP peers with the neighbors on these interfaces without addresses (unnumbered)." : "Without an address, the interface uses the node's router address.")
            }
        }
        .task(id: draft.node) { await loadInterfaces() }
    }

    private func prefixHint(_ prefix: String?) -> LocalizedStringKey {
        prefix.map { LocalizedStringKey("In \($0)") } ?? ""
    }

    @ViewBuilder
    private func interfaceRow(_ interface: NetworkInterface) -> some View {
        let index = draft.interfaces.firstIndex { $0.name == interface.name }
        let hasAddress = interface.cidr != nil || interface.cidr6 != nil
        Toggle(isOn: Binding(get: { index != nil }, set: { on in
            if on { draft.interfaces.append(SDNFabricInterface(name: interface.name)) } else { draft.interfaces.removeAll { $0.name == interface.name } }
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(interface.name)
                Text(([interface.typeTitle] + [interface.cidr, interface.cidr6].compactMap { $0 }).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("sdn.fabricnode.iface.\(interface.name)")
        if let index, protocolType != .bgp, !hasAddress {
            LabeledTextField(title: "IPv4", prompt: "Router address", text: $draft.interfaces[index].ip, keyboard: .numbersAndPunctuation)
                .padding(.leading)
            if protocolType == .openfabric {
                LabeledTextField(title: "IPv6", prompt: "Router address", text: $draft.interfaces[index].ip6, keyboard: .numbersAndPunctuation)
                    .padding(.leading)
            }
            if protocolType == .ospf {
                Picker("Network Type", selection: $draft.interfaces[index].networkType) {
                    Text("Automatic").tag("")
                    ForEach(SDNFabricInterface.networkTypes, id: \.self) { Text($0).tag($0) }
                }
                .padding(.leading)
            }
        }
    }

    /// Interfaces that can carry the fabric: physical ones, bonds, VLANs and bridges, plus the ones already chosen.
    private func loadInterfaces() async {
        guard !draft.node.isEmpty, let network = try? await sdn.connection.send(PVE.network(node: draft.node)) else {
            interfaces = []
            return
        }
        let chosen = Set(draft.interfaces.map(\.name))
        let types: Set<String> = ["eth", "bond", "vlan", "bridge", "OVSBridge", "OVSIntPort"]
        interfaces = network.sortedInterfaces.filter { types.contains($0.type) || chosen.contains($0.name) }
    }
}

// MARK: - Route maps

struct SDNRouteMapsView: View {
    let sdn: SDNSettings
    @State private var adding = false

    var body: some View {
        List {
            if sdn.routeMaps.isEmpty {
                Section {
                    Text("No route maps").foregroundStyle(.secondary)
                }
            }
            ForEach(sdn.routeMaps, id: \.name) { routeMap in
                Section {
                    NavigationLink {
                        SDNRouteMapView(sdn: sdn, name: routeMap.name)
                    } label: {
                        SDNObjectRow(title: routeMap.name, subtitle: routeMap.entries.map { "\($0.order) \($0.action)" }.joined(separator: " · "),
                                     state: routeMap.entries.allSatisfy { $0.state == .deleted } ? .deleted : routeMap.entries.first { $0.state != nil }.map { _ in .changed })
                    }
                    .accessibilityIdentifier("sdn.routemap.\(routeMap.name)")
                }
            }
            Section {
            } footer: {
                Text("A route map goes through its entries by order. The first entry whose conditions match permits or denies the route and can change it. Controllers and fabrics use route maps for the routes they exchange.")
            }
        }
        .navigationTitle("Route Maps")
        .refreshable { await sdn.load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { adding = true }
                    .disabled(!sdn.canModify)
                    .accessibilityIdentifier("sdn.add.routemap")
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { SDNRouteMapEntryEditor(sdn: sdn, entry: nil, draft: SDNRouteMapEntryDraft(order: "10")) }
        }
    }
}

/// The entries of one route map.
private struct SDNRouteMapView: View {
    let sdn: SDNSettings
    let name: String
    @State private var adding = false
    @State private var deleting: SDNRouteMapEntry?
    @State private var errorMessage: String?

    private var entries: [SDNRouteMapEntry] { sdn.routeMaps.first { $0.name == name }?.entries ?? [] }

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    NavigationLink {
                        SDNRouteMapEntryEditor(sdn: sdn, entry: entry, draft: SDNRouteMapEntryDraft(entry))
                    } label: {
                        SDNObjectRow(title: "\(entry.order) · \(entry.action)", subtitle: summary(entry), state: entry.state)
                    }
                    .disabled(entry.state == .deleted)
                    .accessibilityIdentifier("sdn.routemapentry.\(entry.order)")
                    .swipeActions {
                        if sdn.canModify, entry.state != .deleted {
                            Button("Delete", systemImage: "trash") { deleting = entry }
                                .tint(.red)
                        }
                    }
                }
                Button("Add Entry", systemImage: "plus") { adding = true }
                    .disabled(!sdn.canModify)
                    .accessibilityIdentifier("sdn.routemapentry.add")
            } footer: {
                Text("The route map disappears with its last entry.")
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await sdn.load() }
        .sheet(isPresented: $adding) {
            NavigationStack {
                SDNRouteMapEntryEditor(sdn: sdn, entry: nil, draft: SDNRouteMapEntryDraft(routeMap: name, order: String((entries.map(\.order).max() ?? 0) + 10)))
            }
        }
        .confirmationDialog("Delete entry \(deleting?.order ?? 0)?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { entry in
            Button("Delete", role: .destructive) {
                Task {
                    do { try await sdn.deleteRouteMapEntry(routeMap: name, order: entry.order) } catch { errorMessage = error.localizedDescription }
                }
            }
        } message: { _ in
            Text("The deletion takes effect on Apply.")
        }
        .sdnErrorAlert($errorMessage)
    }

    private func summary(_ entry: SDNRouteMapEntry) -> String {
        let match = entry.match.map { String(localized: "if \($0.key) \($0.value)") }
        let set = entry.set.map { String(localized: "set \($0.key) \($0.value)") }
        return (match + set).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " · ")
    }
}

private struct SDNRouteMapEntryEditor: View {
    let sdn: SDNSettings
    let entry: SDNRouteMapEntry?
    let original: SDNRouteMapEntryDraft
    @State private var draft: SDNRouteMapEntryDraft

    init(sdn: SDNSettings, entry: SDNRouteMapEntry?, draft: SDNRouteMapEntryDraft) {
        self.sdn = sdn
        self.entry = entry
        original = draft
        _draft = State(initialValue: draft)
    }

    private var isNew: Bool { entry == nil }
    /// A new route map, as opposed to a new entry of an existing one.
    private var namesRouteMap: Bool { isNew && original.routeMap.isEmpty }

    var body: some View {
        SDNEditorForm(title: namesRouteMap ? String(localized: "New Route Map") : isNew ? String(localized: "New Entry") : "\(draft.routeMap) \(draft.order)",
                      sdn: sdn, isNew: isNew, hasChanges: !draft.changes(from: original).isEmpty, problems: draft.problems(isNew: isNew)) { () throws(ConfigUpdateError) in
            if let entry {
                try await sdn.updateRouteMapEntry(routeMap: entry.routeMap, order: entry.order, draft.changes(from: original))
            } else {
                try await sdn.createRouteMapEntry(draft)
            }
        } content: { errors in
            Section {
                if namesRouteMap {
                    LabeledTextField(title: "Route Map", prompt: "uplink-in", text: $draft.routeMap, identifier: "sdn.routemap.id")
                    FieldError(message: errors["route-map-id"])
                }
                if isNew {
                    LabeledTextField(title: "Order", prompt: "10", text: $draft.order, keyboard: .numberPad, identifier: "sdn.routemap.order")
                    FieldError(message: errors["order"])
                }
                Picker("Action", selection: $draft.action) {
                    Text("Permit").tag("permit")
                    Text("Deny").tag("deny")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("sdn.routemap.action")
            } footer: {
                Text("Entries run from the lowest order up. Leave gaps, such as 10, 20, 30, to insert entries later.")
            }
            ClauseSection(title: "Match", keys: SDNRouteMapMatch.keys, defaultKey: "ip-address-prefix-list", kind: SDNRouteMapMatch.kind, clauses: $draft.match, prefixLists: sdn.prefixListNames,
                          footer: "All conditions must match. Without conditions, every route matches.", identifier: "match")
            FieldError(message: errors["match"])
            ClauseSection(title: "Set", keys: SDNRouteMapSet.keys, defaultKey: "local-preference", kind: SDNRouteMapSet.kind, clauses: $draft.set, prefixLists: [],
                          footer: "Changes made to permitted routes. Local preference and metric take + or - to adjust the current value.", identifier: "set")
            FieldError(message: errors["set"])
            Section {
                NamePicker(title: "Call", names: sdn.routeMapNames.filter { $0 != draft.routeMap }, selection: $draft.call)
                Picker("Exit Policy", selection: $draft.exitAction) {
                    Text("Exit").tag(SDNRouteMapEntryDraft.ExitAction.exit)
                    Text("On Match Next").tag(SDNRouteMapEntryDraft.ExitAction.next)
                    Text("On Match Go To").tag(SDNRouteMapEntryDraft.ExitAction.goto)
                    Text("Continue").tag(SDNRouteMapEntryDraft.ExitAction.continue)
                }
                .accessibilityIdentifier("sdn.routemap.exit")
                if draft.exitAction.needsTarget {
                    LabeledTextField(title: "Target Order", prompt: "20", text: $draft.exitTarget, keyboard: .numberPad)
                    FieldError(message: errors["exit-action"])
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Call runs another route map when this entry matches. After a match the route map normally ends; it can instead go on with the next entry or a given one.")
            }
        }
    }
}

/// Conditions or actions of a route map entry: a key and, for most keys, a value.
private struct ClauseSection: View {
    let title: LocalizedStringKey
    let keys: [String]
    let defaultKey: String
    let kind: (String) -> SDNRouteMapValueKind
    @Binding var clauses: [SDNRouteMapClause]
    let prefixLists: [String]
    let footer: LocalizedStringKey
    let identifier: String

    var body: some View {
        Section {
            ForEach(clauses.indices, id: \.self) { index in
                VStack(alignment: .leading) {
                    Picker("Key", selection: $clauses[index].key) {
                        ForEach(keys, id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("\(identifier).\(index).key")
                    valueField(index)
                }
            }
            .onDelete { clauses.remove(atOffsets: $0) }
            Button(identifier == "match" ? "Add Condition" : "Add Action", systemImage: "plus") {
                clauses.append(SDNRouteMapClause(key: defaultKey))
            }
            .accessibilityIdentifier("\(identifier).add")
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    @ViewBuilder
    private func valueField(_ index: Int) -> some View {
        switch kind(clauses[index].key) {
        case .none:
            EmptyView()
        case .choice(let options):
            Picker("Value", selection: $clauses[index].value) {
                if !options.contains(clauses[index].value) { Text("Choose").tag(clauses[index].value) }
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        case .prefixList:
            Picker("Prefix List", selection: $clauses[index].value) {
                if !prefixLists.contains(clauses[index].value) { Text(clauses[index].value.isEmpty ? "Choose" : clauses[index].value).tag(clauses[index].value) }
                ForEach(prefixLists, id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("\(identifier).\(index).list")
        case .number:
            LabeledTextField(title: "Value", prompt: "100", text: $clauses[index].value, keyboard: .numbersAndPunctuation, identifier: "\(identifier).\(index).value")
        case .ipv4, .ipv6, .text:
            LabeledTextField(title: "Value", prompt: "", text: $clauses[index].value, keyboard: .numbersAndPunctuation, identifier: "\(identifier).\(index).value")
        }
    }
}

// MARK: - Prefix lists

struct SDNPrefixListsView: View {
    let sdn: SDNSettings
    @State private var adding = false
    @State private var newName = ""
    @State private var deleting: SDNObject?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if sdn.prefixLists.isEmpty {
                    Text("No prefix lists").foregroundStyle(.secondary)
                }
                ForEach(sdn.prefixLists) { list in
                    NavigationLink {
                        SDNPrefixListView(sdn: sdn, list: list.id)
                    } label: {
                        SDNObjectRow(title: list.id, subtitle: "", state: list.state)
                    }
                    .disabled(list.state == .deleted)
                    .accessibilityIdentifier("sdn.prefixlist.\(list.id)")
                    .swipeActions {
                        if sdn.canModify, list.state != .deleted {
                            Button("Delete", systemImage: "trash") { deleting = list }
                                .tint(.red)
                        }
                    }
                }
            } footer: {
                Text("Prefix lists name groups of networks for route maps and fabric route filters.")
            }
        }
        .navigationTitle("Prefix Lists")
        .refreshable { await sdn.load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") {
                    newName = ""
                    adding = true
                }
                .disabled(!sdn.canModify)
                .accessibilityIdentifier("sdn.add.prefixlist")
            }
        }
        .alert("New Prefix List", isPresented: $adding) {
            TextField("Name", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("sdn.prefixlist.name")
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                Task {
                    do { try await sdn.createPrefixList(newName.trimmingCharacters(in: .whitespaces)) } catch { errorMessage = error.localizedDescription }
                }
            }
        } message: {
            Text("Letters, digits, - and _.")
        }
        .confirmationDialog("Delete the prefix list \(deleting?.id ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { list in
            Button("Delete", role: .destructive) {
                Task {
                    do { try await sdn.deletePrefixList(list.id) } catch { errorMessage = error.localizedDescription }
                }
            }
        } message: { _ in
            Text("The deletion takes effect on Apply.")
        }
        .sdnErrorAlert($errorMessage)
    }
}

/// The entries of one prefix list, as they will be after Apply.
private struct SDNPrefixListView: View {
    let sdn: SDNSettings
    let list: String
    @State private var entries: [SDNPrefixListEntry]?
    @State private var editing: Editing?
    @State private var deleting: SDNPrefixListEntry?
    @State private var errorMessage: String?

    struct Editing: Identifiable {
        var entry: SDNPrefixListEntry?
        var id: Int { entry?.sequence ?? -1 }
    }

    var body: some View {
        List {
            Section {
                ForEach(entries ?? []) { entry in
                    Button {
                        editing = Editing(entry: entry)
                    } label: {
                        HStack {
                            Text(String(entry.sequence)).foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 30, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.prefix).font(.body.monospaced())
                                Text(([entry.action == "deny" ? String(localized: "Deny") : String(localized: "Permit")]
                                      + [entry.ge.map { String(localized: "length ≥ \($0)") }, entry.le.map { String(localized: "length ≤ \($0)") }].compactMap { $0 })
                                    .joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(entry.action == "deny" ? .red : .secondary)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("sdn.prefixentry.\(entry.sequence)")
                    .swipeActions {
                        if sdn.canModify {
                            Button("Delete", systemImage: "trash") { deleting = entry }
                                .tint(.red)
                        }
                    }
                }
                Button("Add Entry", systemImage: "plus") { editing = Editing() }
                    .disabled(!sdn.canModify)
                    .accessibilityIdentifier("sdn.prefixentry.add")
            } footer: {
                Text("Entries are checked by sequence number; the first that covers a route decides. Routes no entry covers are denied.")
            }
        }
        .overlay { if entries == nil, errorMessage == nil { ProgressView() } }
        .navigationTitle(list)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { editing in
            NavigationStack { SDNPrefixListEntryEditor(sdn: sdn, list: list, entry: editing.entry) }
        }
        .confirmationDialog("Delete entry \(deleting?.sequence ?? 0)?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { entry in
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await sdn.deletePrefixListEntry(list: list, sequence: entry.sequence)
                        await load()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        } message: { _ in
            Text("The deletion takes effect on Apply.")
        }
        .sdnErrorAlert($errorMessage)
    }

    private func load() async {
        do {
            entries = try await sdn.prefixListEntries(list)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SDNPrefixListEntryEditor: View {
    let sdn: SDNSettings
    let list: String
    let entry: SDNPrefixListEntry?
    let original: SDNPrefixListEntryDraft
    @State private var draft: SDNPrefixListEntryDraft

    init(sdn: SDNSettings, list: String, entry: SDNPrefixListEntry?) {
        self.sdn = sdn
        self.list = list
        self.entry = entry
        let draft = entry.map(SDNPrefixListEntryDraft.init) ?? SDNPrefixListEntryDraft()
        original = draft
        _draft = State(initialValue: draft)
    }

    var body: some View {
        SDNEditorForm(title: entry.map { String(localized: "Entry \($0.sequence)") } ?? String(localized: "New Entry"), sdn: sdn, isNew: entry == nil,
                      hasChanges: !draft.changes(from: original).isEmpty, problems: draft.problems) { () throws(ConfigUpdateError) in
            if let entry {
                try await sdn.updatePrefixListEntry(list: list, sequence: entry.sequence, draft.changes(from: original))
            } else {
                try await sdn.createPrefixListEntry(list: list, draft)
            }
        } content: { errors in
            Section {
                Picker("Action", selection: $draft.action) {
                    Text("Permit").tag("permit")
                    Text("Deny").tag("deny")
                }
                .pickerStyle(.segmented)
                LabeledTextField(title: "Prefix", prompt: "10.0.0.0/8", text: $draft.prefix, keyboard: .numbersAndPunctuation, identifier: "sdn.prefixentry.prefix")
                FieldError(message: errors["prefix"])
                if entry == nil {
                    LabeledTextField(title: "Sequence", prompt: "Next", text: $draft.sequence, keyboard: .numberPad)
                    FieldError(message: errors["seq"])
                }
            }
            Section {
                LabeledTextField(title: "Minimum Length", prompt: "Exact", text: $draft.ge, keyboard: .numberPad, identifier: "sdn.prefixentry.ge")
                FieldError(message: errors["ge"])
                LabeledTextField(title: "Maximum Length", prompt: "Exact", text: $draft.le, keyboard: .numberPad, identifier: "sdn.prefixentry.le")
                FieldError(message: errors["le"])
            } header: {
                Text("Prefix Length")
            } footer: {
                Text("Without lengths the entry covers exactly this prefix. With them it covers any network inside it whose prefix length is in the range, e.g. 10.0.0.0/8 up to /24.")
            }
        }
    }
}
