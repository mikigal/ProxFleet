import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// The datacenter's PCI, USB and directory mappings, checked against one node.
@MainActor
@Observable
public final class ResourceMappingList {
    public let connection: ServerConnection

    public private(set) var mappings: [ResourceMappingKind: [ResourceMappingDetail]] = [:]
    /// The node whose devices and directories the checks are about.
    public var checkedNode: String?
    public private(set) var privileges: Set<String>?
    public private(set) var loadError: String?

    public init(connection: ServerConnection) {
        self.connection = connection
        checkedNode = connection.snapshot?.nodes.first(where: \.isOnline)?.name
    }

    /// Changing mappings needs `Mapping.Modify` on `/mapping`.
    public var canModify: Bool { privileges?.contains("Mapping.Modify") ?? true }

    public func load() async {
        async let privileges = try? connection.session.privileges(on: "/mapping")
        do {
            var mappings: [ResourceMappingKind: [ResourceMappingDetail]] = [:]
            for kind in ResourceMappingKind.allCases {
                mappings[kind] = try await connection.session.send(PVE.resourceMappingDetails(kind, checkNode: checkedNode)).sorted { $0.id < $1.id }
            }
            self.mappings = mappings
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        if let privileges = await privileges { self.privileges = privileges }
    }

    public func create(_ draft: ResourceMappingDraft) async throws(ConfigUpdateError) {
        try await perform(PVE.createResourceMapping(draft))
    }

    public func update(_ kind: ResourceMappingKind, id: String, _ changes: APIParameters, digest: String?) async throws(ConfigUpdateError) {
        guard !changes.isEmpty else { return }
        try await perform(PVE.updateResourceMapping(kind, id: id, changes, digest: digest))
    }

    /// Guests that use the mapping stop working until it is created again.
    public func delete(_ kind: ResourceMappingKind, id: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteResourceMapping(kind, id: id))
    }

    /// Host devices of a node, for choosing what a mapping points to.
    public func pciDevices(node: String) async -> [NodePCIDevice] {
        ((try? await connection.session.send(PVE.pciDevices(node: node))) ?? []).sorted { $0.id < $1.id }
    }

    public func usbDevices(node: String) async -> [NodeUSBDevice] {
        ((try? await connection.session.send(PVE.usbDevices(node: node))) ?? []).filter { !$0.isHub }
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
