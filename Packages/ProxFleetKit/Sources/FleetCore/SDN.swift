import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// The datacenter's software-defined networks: zones, VNets and their subnets, plus the routing side (controllers,
/// fabrics, prefix lists, route maps). Changes wait as pending until they are applied to the nodes, like in the
/// web interface.
@MainActor
@Observable
public final class SDNSettings {
    public let connection: ServerConnection

    public private(set) var zones: [SDNObject]?
    public private(set) var vnets: [SDNObject]?
    public private(set) var subnets: [String: [SDNObject]] = [:]
    public private(set) var ipams: [SDNPlugin] = []
    public private(set) var dnsServers: [SDNPlugin] = []
    public private(set) var controllers: [SDNObject] = []
    public private(set) var fabrics: [SDNObject] = []
    public private(set) var fabricNodes: [SDNObject] = []
    public private(set) var prefixLists: [SDNObject] = []
    public private(set) var routeMapEntries: [SDNRouteMapEntry] = []
    /// Zone status by node, then zone.
    public private(set) var zoneStatus: [String: [String: String]] = [:]
    public private(set) var privileges: Set<String>?
    public private(set) var loadError: String?

    public init(connection: ServerConnection) {
        self.connection = connection
    }

    /// Changing SDN needs `SDN.Allocate` on `/sdn`.
    public var canModify: Bool { privileges?.contains("SDN.Allocate") ?? true }

    /// Whether anything waits for Apply.
    public var hasPendingChanges: Bool {
        let objects = (zones ?? []) + (vnets ?? []) + subnets.values.flatMap { $0 } + controllers + fabrics + fabricNodes + prefixLists
        return objects.contains { $0.state != nil } || routeMapEntries.contains { $0.state != nil }
    }

    /// Route maps by name, with their entries in order.
    public var routeMaps: [(name: String, entries: [SDNRouteMapEntry])] {
        Dictionary(grouping: routeMapEntries, by: \.routeMap)
            .map { (name: $0.key, entries: $0.value.sorted { $0.order < $1.order }) }
            .sorted { $0.name < $1.name }
    }

    /// Names to pick from where a route map is used; ones only pending deletion are left out.
    public var routeMapNames: [String] {
        routeMaps.filter { $0.entries.contains { $0.state != .deleted } }.map(\.name)
    }

    public var prefixListNames: [String] { prefixLists.filter { $0.state != .deleted }.map(\.id) }

    public func nodes(ofFabric fabric: String) -> [SDNObject] {
        fabricNodes.filter { $0.fabricID == fabric }.sorted { $0.id < $1.id }
    }

    public func zoneType(_ zone: String) -> SDNZoneType? {
        zones?.first { $0.id == zone }.flatMap { SDNZoneType(rawValue: $0.type) }
    }

    public func load() async {
        let session = connection.session
        async let privileges = try? session.privileges(on: "/sdn")
        async let ipams = try? session.send(PVE.sdnIPAMs())
        async let dnsServers = try? session.send(PVE.sdnDNSServers())
        // Fabrics, prefix lists and route maps came with Proxmox VE 9; older servers lack them.
        async let fabrics = try? session.send(PVE.sdnFabrics())
        async let prefixLists = try? session.send(PVE.sdnPrefixLists())
        async let routeMapEntries = try? session.send(PVE.sdnRouteMapEntries())
        async let status = zoneStatusByNode()
        do {
            async let zones = session.send(PVE.sdnZones())
            async let vnets = session.send(PVE.sdnVNets())
            async let controllers = session.send(PVE.sdnControllers())
            let loadedVNets = try await vnets.sorted { $0.id < $1.id }
            let subnets = try await withThrowingTaskGroup(of: (String, [SDNObject]).self) { group in
                for vnet in loadedVNets {
                    group.addTask { (vnet.id, try await session.send(PVE.sdnSubnets(vnet: vnet.id))) }
                }
                var subnets: [String: [SDNObject]] = [:]
                for try await (vnet, list) in group { subnets[vnet] = list.sorted { ($0["cidr"] ?? "") < ($1["cidr"] ?? "") } }
                return subnets
            }
            self.zones = try await zones.sorted { $0.id < $1.id }
            self.controllers = try await controllers.sorted { $0.id < $1.id }
            self.vnets = loadedVNets
            self.subnets = subnets
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        self.ipams = await ipams ?? []
        self.dnsServers = await dnsServers ?? []
        if let fabrics = await fabrics {
            self.fabrics = fabrics.fabrics.sorted { $0.id < $1.id }
            fabricNodes = fabrics.nodes
        }
        self.prefixLists = (await prefixLists ?? []).sorted { $0.id < $1.id }
        self.routeMapEntries = (await routeMapEntries ?? []).map(SDNRouteMapEntry.init)
        zoneStatus = await status
        if let privileges = await privileges { self.privileges = privileges }
    }

    /// Zone status by node, then zone.
    private func zoneStatusByNode() async -> [String: [String: String]] {
        let session = connection.session
        let nodes = connection.snapshot?.nodes.filter(\.isOnline).map(\.name) ?? []
        return await withTaskGroup(of: (String, [SDNZoneStatus]?).self) { group in
            for node in nodes {
                group.addTask { (node, try? await session.send(PVE.sdnZoneStatus(node: node))) }
            }
            var status: [String: [String: String]] = [:]
            for await (node, zones) in group {
                if let zones { status[node] = Dictionary(zones.map { ($0.zone, $0.status) }) { first, _ in first } }
            }
            return status
        }
    }

    // MARK: - Zones, VNets, subnets

    public func createZone(_ draft: SDNZoneDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createSDNZone(draft))
    }

    public func updateZone(_ id: String, _ update: SDNUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        try await perform(PVE.updateSDNZone(id, update))
    }

    /// Zones with VNets cannot be deleted.
    public func deleteZone(_ id: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteSDNZone(id))
    }

    public func createVNet(_ draft: SDNVNetDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createSDNVNet(draft, zoneType: zoneType(draft.zone)))
    }

    public func updateVNet(_ id: String, _ update: SDNUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        try await perform(PVE.updateSDNVNet(id, update))
    }

    /// VNets with subnets cannot be deleted.
    public func deleteVNet(_ id: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteSDNVNet(id))
    }

    public func createSubnet(vnet: String, _ draft: SDNSubnetDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createSDNSubnet(vnet: vnet, draft))
    }

    public func updateSubnet(vnet: String, id: String, _ update: SDNUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        try await perform(PVE.updateSDNSubnet(vnet: vnet, id: id, update))
    }

    public func deleteSubnet(vnet: String, id: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteSDNSubnet(vnet: vnet, id: id))
    }

    // MARK: - Controllers, fabrics, prefix lists, route maps

    public func createController(_ draft: SDNControllerDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createSDNController(draft))
    }

    public func updateController(_ id: String, _ update: SDNUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        try await perform(PVE.updateSDNController(id, update))
    }

    public func deleteController(_ id: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteSDNController(id))
    }

    public func createFabric(_ draft: SDNFabricDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createSDNFabric(draft))
    }

    public func updateFabric(_ id: String, protocol protocolType: SDNFabricProtocol, _ update: SDNUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        try await perform(PVE.updateSDNFabric(id, protocol: protocolType, update))
    }

    public func deleteFabric(_ id: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteSDNFabric(id))
    }

    public func addFabricNode(fabric: String, _ draft: SDNFabricNodeDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.addSDNFabricNode(fabric: fabric, draft))
    }

    public func updateFabricNode(fabric: String, node: String, protocol protocolType: SDNFabricProtocol, _ update: SDNUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        try await perform(PVE.updateSDNFabricNode(fabric: fabric, node: node, protocol: protocolType, update))
    }

    public func removeFabricNode(fabric: String, node: String) async throws(ConfigUpdateError) {
        try await perform(PVE.removeSDNFabricNode(fabric: fabric, node: node))
    }

    public func createPrefixList(_ id: String) async throws(ConfigUpdateError) {
        try await perform(PVE.createSDNPrefixList(id))
    }

    public func deletePrefixList(_ id: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteSDNPrefixList(id))
    }

    public func prefixListEntries(_ id: String) async throws(ConfigUpdateError) -> [SDNPrefixListEntry] {
        do {
            return try await connection.session.send(PVE.sdnPrefixListEntries(id)).sorted { $0.sequence < $1.sequence }
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    public func createPrefixListEntry(list: String, _ draft: SDNPrefixListEntryDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createSDNPrefixListEntry(list: list, draft))
    }

    public func updatePrefixListEntry(list: String, sequence: Int, _ update: SDNUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        try await perform(PVE.updateSDNPrefixListEntry(list: list, sequence: sequence, update))
    }

    public func deletePrefixListEntry(list: String, sequence: Int) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteSDNPrefixListEntry(list: list, sequence: sequence))
    }

    public func createRouteMapEntry(_ draft: SDNRouteMapEntryDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createSDNRouteMapEntry(draft))
    }

    public func updateRouteMapEntry(routeMap: String, order: Int, _ update: SDNUpdate) async throws(ConfigUpdateError) {
        guard !update.isEmpty else { return }
        try await perform(PVE.updateSDNRouteMapEntry(routeMap: routeMap, order: order, update))
    }

    public func deleteRouteMapEntry(routeMap: String, order: Int) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteSDNRouteMapEntry(routeMap: routeMap, order: order))
    }

    // MARK: - IP mappings

    /// IPAM changes take effect right away, without Apply.
    public func createIPMapping(vnet: String, zone: String, ip: String, mac: String) async throws(ConfigUpdateError) {
        try await send(PVE.createIPMapping(vnet: vnet, zone: zone, ip: ip, mac: mac))
    }

    public func updateIPMapping(vnet: String, zone: String, ip: String, mac: String, vmid: Int?) async throws(ConfigUpdateError) {
        try await send(PVE.updateIPMapping(vnet: vnet, zone: zone, ip: ip, mac: mac, vmid: vmid))
    }

    public func deleteIPMapping(vnet: String, zone: String, ip: String, mac: String?) async throws(ConfigUpdateError) {
        try await send(PVE.deleteIPMapping(vnet: vnet, zone: zone, ip: ip, mac: mac))
    }

    private func send(_ request: APIRequest<Nothing>) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.session.send(request)
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    // MARK: - Apply

    /// Writes the pending configuration to the nodes and reloads their networks.
    public func apply() async throws(ConfigUpdateError) -> TaskCenter.TrackedTask {
        try await connection.start(PVE.applySDN())
    }

    public func rollback() async throws(ConfigUpdateError) {
        try await perform(PVE.rollbackSDN())
    }

    public func ipamEntries(_ ipam: String) async throws(ConfigUpdateError) -> [IPAMEntry] {
        do {
            return try await connection.session.send(PVE.ipamEntries(ipam))
        } catch {
            throw ConfigUpdateError(error)
        }
    }

    private func perform(_ request: APIRequest<Nothing>) async throws(ConfigUpdateError) {
        do {
            _ = try await connection.session.send(request)
        } catch {
            throw ConfigUpdateError(error)
        }
        await load()
    }
}
