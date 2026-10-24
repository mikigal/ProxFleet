import FleetCore
import ProxmoxCore
import PVEKit
import SwiftUI

/// The SDN of one node, like the zones and fabrics under a node in the web interface's resource tree: whether they
/// work there, what their bridges carry, and the routes and neighbors FRR knows.
struct NodeSDNView: View {
    let connection: ServerConnection
    let node: String
    @State private var networks: [SDNNodeNetwork]?
    @State private var errorMessage: String?

    private var zones: [SDNNodeNetwork] {
        (networks ?? []).filter { $0.kind == .zone }.sorted { ($0.isLocalNetwork ? 0 : 1, $0.name) < ($1.isLocalNetwork ? 0 : 1, $1.name) }
    }

    private var fabrics: [SDNNodeNetwork] { (networks ?? []).filter { $0.kind == .fabric }.sorted { $0.name < $1.name } }

    var body: some View {
        List {
            if networks != nil {
                Section {
                    ForEach(zones) { zone in
                        // Before PVE 9.1 nodes cannot show their bridges, which is all the local network has.
                        if zone.isLocalNetwork, !connection.supports(.sdnNodeStatus) {
                            SDNNetworkRow(network: zone)
                                .accessibilityIdentifier("sdnstatus.zone.\(zone.name)")
                        } else {
                            NavigationLink {
                                SDNZoneStatusView(connection: connection, network: zone)
                            } label: {
                                SDNNetworkRow(network: zone)
                            }
                            .accessibilityIdentifier("sdnstatus.zone.\(zone.name)")
                        }
                    }
                } header: {
                    Text("Zones")
                } footer: {
                    Text("Local Network is the node's own bridges. SDN zones show here after Apply.")
                }
                if !fabrics.isEmpty {
                    Section("Fabrics") {
                        ForEach(fabrics) { fabric in
                            NavigationLink {
                                SDNFabricStatusView(connection: connection, network: fabric)
                            } label: {
                                SDNNetworkRow(network: fabric)
                            }
                            .accessibilityIdentifier("sdnstatus.fabric.\(fabric.name)")
                        }
                    }
                }
            }
        }
        .overlay {
            if let errorMessage, networks == nil {
                ContentUnavailableView("Cannot Load SDN", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if networks == nil {
                ProgressView()
            }
        }
        .navigationTitle("SDN")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            networks = try await connection.send(PVE.sdnNodeNetworks()).filter { $0.kind != nil && $0.node == node }
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SDNNetworkRow: View {
    let network: SDNNodeNetwork

    var body: some View {
        HStack {
            Image(systemName: network.kind == .fabric ? "point.3.connected.trianglepath.dotted" : network.isLocalNetwork ? "network" : "square.stack.3d.up")
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(network.isLocalNetwork ? String(localized: "Local Network") : network.name)
                if let detail = network.zoneType ?? network.fabricProtocol {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            SDNStatusBadge(status: network.status)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SDNStatusBadge: View {
    let status: String

    private var isGood: Bool { ["ok", "available", "up", "full", "established"].contains(status.lowercased()) || status.lowercased().hasPrefix("full") }

    var body: some View {
        Text(status)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((isGood ? Color.green : Color.orange).opacity(0.18), in: .capsule)
            .foregroundStyle(isGood ? Color.green : Color.orange)
    }
}

/// A zone on a node: its VNets with their state, its bridges with the guests on them, and for EVPN the IP and MAC VRFs.
private struct SDNZoneStatusView: View {
    let connection: ServerConnection
    let network: SDNNodeNetwork
    @State private var content: [SDNZoneContentEntry]?
    @State private var bridges: [SDNBridge]?
    @State private var ipVRF: [SDNIPVRFRoute]?
    @State private var macVNet = ""
    @State private var macVRF: [SDNMACVRFEntry]?
    @State private var errorMessage: String?

    private var isEVPN: Bool { network.zoneType == "evpn" }

    var body: some View {
        List {
            if !network.isLocalNetwork {
                Section("VNets") {
                    if content?.isEmpty == true {
                        Text("No VNets").foregroundStyle(.secondary)
                    }
                    ForEach(content ?? []) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.vnet)
                                if let message = entry.statusMessage, !message.isEmpty {
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let status = entry.status { SDNStatusBadge(status: status) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            ForEach(bridges ?? []) { bridge in
                Section {
                    if bridge.ports.isEmpty {
                        Text("No ports").foregroundStyle(.secondary)
                    }
                    ForEach(bridge.ports) { port in
                        HStack {
                            Image(systemName: port.vmid == nil ? "cable.connector" : "desktopcomputer")
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(guestTitle(port) ?? port.name)
                                Text([port.vmid == nil ? nil : port.name, vlanText(port)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("sdnstatus.port.\(port.name)")
                    }
                } header: {
                    Text(bridge.isVLANAware ? "\(bridge.name) · VLAN aware" : bridge.name)
                }
            }
            if isEVPN {
                Section {
                    if ipVRF?.isEmpty == true {
                        Text("No routes").foregroundStyle(.secondary)
                    }
                    ForEach(ipVRF ?? []) { route in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(route.prefix).font(.body.monospaced())
                            Text([route.protocolName, route.metric.map { String(localized: "metric \($0)") }, route.nexthops.isEmpty ? nil : "via " + route.nexthops.joined(separator: ", ")].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("IP-VRF")
                } footer: {
                    Text("Routes of the zone's VRF on this node, without the guests on this node.")
                }
                Section {
                    Picker("VNet", selection: $macVNet) {
                        ForEach(content ?? []) { Text($0.vnet).tag($0.vnet) }
                    }
                    if macVRF?.isEmpty == true {
                        Text("No entries").foregroundStyle(.secondary)
                    }
                    ForEach(macVRF ?? []) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.mac).font(.body.monospaced())
                            Text([entry.ip, entry.nexthop.map { "via \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("MAC-VRF")
                } footer: {
                    Text("MAC addresses the VNet learned via BGP or announces itself.")
                }
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(network.isLocalNetwork ? String(localized: "Local Network") : network.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .task(id: macVNet) { await loadMACVRF() }
    }

    private func guestTitle(_ port: SDNBridge.Port) -> String? {
        guard let vmid = port.vmid else { return nil }
        let name = connection.snapshot?.guests.first { $0.vmid == vmid }?.name
        return [String(vmid), name, port.device].compactMap { $0 }.joined(separator: " · ")
    }

    private func vlanText(_ port: SDNBridge.Port) -> String? {
        var parts: [String] = []
        if let primary = port.primaryVLAN { parts.append(String(localized: "PVID \(primary)")) }
        if !port.vlans.isEmpty { parts.append(String(localized: "VLANs \(port.vlans.joined(separator: ","))")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            if !network.isLocalNetwork {
                content = try await connection.send(PVE.sdnZoneContent(node: network.node, zone: network.name))
                if macVNet.isEmpty { macVNet = content?.first?.vnet ?? "" }
            }
            if connection.supports(.sdnNodeStatus) {
                bridges = try await connection.send(PVE.sdnZoneBridges(node: network.node, zone: network.name))
            }
            if isEVPN { ipVRF = try await connection.send(PVE.sdnIPVRF(node: network.node, zone: network.name)) }
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMACVRF() async {
        guard isEVPN, !macVNet.isEmpty else { return }
        do {
            macVRF = try await connection.send(PVE.sdnMACVRF(node: network.node, vnet: macVNet))
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A fabric on a node: its routes, its neighbors and its interfaces, as FRR reports them.
private struct SDNFabricStatusView: View {
    let connection: ServerConnection
    let network: SDNNodeNetwork
    @State private var part = 0
    @State private var routes: [SDNFabricRoute]?
    @State private var neighbors: [SDNFabricNeighbor]?
    @State private var interfaces: [SDNFabricInterfaceStatus]?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Picker("Part", selection: $part) {
                    Text("Routes").tag(0)
                    Text("Neighbors").tag(1)
                    Text("Interfaces").tag(2)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                switch part {
                case 0:
                    if routes?.isEmpty == true { Text("No routes").foregroundStyle(.secondary) }
                    ForEach(routes ?? []) { route in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(route.route).font(.body.monospaced())
                            if !route.via.isEmpty {
                                Text("via " + route.via.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                case 1:
                    if neighbors?.isEmpty == true { Text("No neighbors").foregroundStyle(.secondary) }
                    ForEach(neighbors ?? []) { neighbor in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(neighbor.neighbor)
                                if let uptime = neighbor.uptime {
                                    Text(String(localized: "Up \(uptime)"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let status = neighbor.status { SDNStatusBadge(status: status) }
                        }
                    }
                default:
                    if interfaces?.isEmpty == true { Text("No interfaces").foregroundStyle(.secondary) }
                    ForEach(interfaces ?? []) { interface in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(interface.name)
                                if let type = interface.type {
                                    Text(type)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let state = interface.state { SDNStatusBadge(status: state) }
                        }
                        .accessibilityIdentifier("sdnstatus.interface.\(interface.name)")
                    }
                }
            } footer: {
                Text(network.fabricProtocol.map { String(localized: "As FRR's \($0) reports them on \(network.node).") } ?? "")
            }
            ErrorSection(message: errorMessage)
        }
        .navigationTitle(network.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            async let routes = connection.send(PVE.sdnFabricRoutes(node: network.node, fabric: network.name))
            async let neighbors = connection.send(PVE.sdnFabricNeighbors(node: network.node, fabric: network.name))
            async let interfaces = connection.send(PVE.sdnFabricInterfaces(node: network.node, fabric: network.name))
            self.routes = try await routes
            self.neighbors = try await neighbors
            self.interfaces = try await interfaces
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
