import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// The datacenter's software-defined networks: zones, VNets and their subnets. Changes wait as pending until
/// they are applied to the nodes, like in the web interface.
@MainActor
@Observable
public final class SDNSettings {
    public let connection: ServerConnection

    public private(set) var zones: [SDNObject]?
    public private(set) var vnets: [SDNObject]?
    public private(set) var subnets: [String: [SDNObject]] = [:]
    public private(set) var ipams: [SDNPlugin] = []
    public private(set) var dnsServers: [SDNPlugin] = []
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
        (zones ?? []).contains { $0.state != nil } || (vnets ?? []).contains { $0.state != nil }
            || subnets.values.contains { $0.contains { $0.state != nil } }
    }

    public func zoneType(_ zone: String) -> SDNZoneType? {
        zones?.first { $0.id == zone }.flatMap { SDNZoneType(rawValue: $0.type) }
    }

    public func load() async {
        async let privileges = try? connection.session.privileges(on: "/sdn")
        do {
            zones = try await connection.session.send(PVE.sdnZones()).sorted { $0.id < $1.id }
            let vnets = try await connection.session.send(PVE.sdnVNets()).sorted { $0.id < $1.id }
            var subnets: [String: [SDNObject]] = [:]
            for vnet in vnets {
                subnets[vnet.id] = try await connection.session.send(PVE.sdnSubnets(vnet: vnet.id)).sorted { ($0["cidr"] ?? "") < ($1["cidr"] ?? "") }
            }
            self.vnets = vnets
            self.subnets = subnets
            ipams = (try? await connection.session.send(PVE.sdnIPAMs())) ?? []
            dnsServers = (try? await connection.session.send(PVE.sdnDNSServers())) ?? []
            var status: [String: [String: String]] = [:]
            for node in connection.snapshot?.nodes.filter(\.isOnline) ?? [] {
                if let zones = try? await connection.session.send(PVE.sdnZoneStatus(node: node.name)) {
                    status[node.name] = Dictionary(zones.map { ($0.zone, $0.status) }) { first, _ in first }
                }
            }
            zoneStatus = status
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        if let privileges = await privileges { self.privileges = privileges }
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
