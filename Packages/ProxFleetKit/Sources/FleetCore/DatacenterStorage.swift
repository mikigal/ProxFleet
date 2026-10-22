import Foundation
import Observation
import ProxmoxCore
import PVEKit

/// The storage definitions of the datacenter (`storage.cfg`), shared by all nodes of a cluster.
@MainActor
@Observable
public final class DatacenterStorage {
    public let connection: ServerConnection

    public private(set) var configs: [StorageConfig]?
    public private(set) var privileges: Set<String>?
    public private(set) var loadError: String?

    public init(connection: ServerConnection) {
        self.connection = connection
    }

    /// Changing storage definitions needs `Datastore.Allocate` on `/storage`.
    public var canModify: Bool { privileges?.contains("Datastore.Allocate") ?? true }

    /// A node to run scans on: the first online one.
    public var scanNode: String? {
        connection.snapshot?.nodes.first(where: \.isOnline)?.name
    }

    public var nodeNames: [String] {
        connection.snapshot?.nodes.map(\.name) ?? []
    }

    public func load() async {
        async let privileges = try? connection.session.privileges(on: "/storage")
        do {
            configs = try await connection.session.send(PVE.storageConfigs()).sorted { $0.storage.localizedStandardCompare($1.storage) == .orderedAscending }
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        if let privileges = await privileges { self.privileges = privileges }
    }

    /// Returns the encryption key Proxmox generated for a PBS storage, which it shows only this once.
    @discardableResult
    public func create(_ draft: StorageConfigDraft) async throws(ConfigUpdateError) -> String? {
        let result = try await change(PVE.createStorage(draft))
        await reload()
        return result?.encryptionKey
    }

    /// Sends the changes with the digest of the configuration the form was opened with. Returns a newly generated
    /// PBS encryption key.
    @discardableResult
    public func update(_ storage: String, _ update: GuestConfigUpdate, digest: String?) async throws(ConfigUpdateError) -> String? {
        var update = update
        update.digest = digest
        let result = try await change(PVE.updateStorage(storage, update))
        await reload()
        return result?.encryptionKey
    }

    public func delete(_ storage: String) async throws(ConfigUpdateError) {
        try await perform(PVE.deleteStorage(storage))
        await reload()
    }

    public func scan(_ request: APIRequest<[StorageScanResult]>) async throws -> [StorageScanResult] {
        try await connection.session.send(request)
    }

    /// The overview's storage list comes from the cluster resources, so it is refreshed as well.
    private func reload() async {
        await load()
        await connection.refresh()
    }

    private func change(_ request: APIRequest<StorageChangeResult?>) async throws(ConfigUpdateError) -> StorageChangeResult? {
        do {
            return try await connection.session.send(request)
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
    }
}
