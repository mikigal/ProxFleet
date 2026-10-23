import Foundation
import ProxmoxCore

/// Migration of guests between the demo cluster's nodes: one guest, all of a node's, or any from the datacenter.
extension DemoState {
    /// `GET` and `POST .../migrate` of one guest. Returns nil for other paths.
    func handleMigration(_ method: HTTPMethod, rest: [String], guest: DemoCluster.Guest, parameters: [String: String], user: String) -> HTTPResponse? {
        guard rest == ["migrate"] else { return nil }
        switch method {
        case .get: return success(migrationPreconditions(guest))
        case .post:
            guard privileges(for: user).contains("VM.Migrate") else { return failure(403, "Permission check failed (/vms/\(guest.vmid), VM.Migrate)") }
            let online = parameters["online"] == "1" || parameters["restart"] == "1"
            return startMigration(guest, target: parameters["target"] ?? "", online: online, withLocalDisks: parameters["with-local-disks"] == "1", user: user)
        default: return nil
        }
    }

    /// `POST /nodes/{node}/migrateall`: one task, plus a migration task for every chosen guest of the node.
    func migrateAll(node: String, parameters: [String: String], user: String) -> HTTPResponse {
        guard privileges(for: user).contains("VM.Migrate") else { return failure(403, "Permission check failed (/, VM.Migrate)") }
        let target = parameters["target"] ?? ""
        if let problem = targetProblem(target, source: node) { return problem }
        let chosen = parameters["vms"].map { Set($0.split(separator: ",").compactMap { Int($0) }) }
        let guests = cluster.guests.filter { $0.node == node && (chosen?.contains($0.vmid) ?? true) }
        return bulkMigrate(guests, type: "migrateall", node: node, target: target, withLocalDisks: parameters["with-local-disks"] == "1", user: user)
    }

    /// `POST /cluster/bulk-action/guest/migrate`. Like Proxmox, guests already on the target are skipped.
    func clusterBulkMigrate(parameters: [String: String], user: String) -> HTTPResponse {
        guard privileges(for: user).contains("VM.Migrate") else { return failure(403, "Permission check failed (/, VM.Migrate)") }
        let target = parameters["target"] ?? ""
        if let problem = targetProblem(target, source: nil) { return problem }
        let chosen = parameters["vms"].map { Set($0.split(separator: Character(Self.listSeparator)).compactMap { Int($0) }) }
        let online = Set(cluster.nodes.filter(\.isOnline).map(\.name))
        let guests = cluster.guests.filter { online.contains($0.node) && $0.node != target && (chosen?.contains($0.vmid) ?? true) }
        let node = cluster.nodes.first(where: \.isOnline)?.name ?? "pve"
        return bulkMigrate(guests, type: "bulk-migrate", node: node, target: target, withLocalDisks: parameters["with-local-disks"] == "1", user: user)
    }

    private func bulkMigrate(_ guests: [DemoCluster.Guest], type: String, node: String, target: String, withLocalDisks: Bool, user: String) -> HTTPResponse {
        var failed = false
        for guest in guests {
            if migrationProblem(guest, target: target, online: true, withLocalDisks: withLocalDisks) != nil || localCDROM(of: guest) != nil {
                failed = true
            }
            _ = startMigration(guest, target: target, online: true, withLocalDisks: withLocalDisks, user: user)
        }
        return startTask(node: node, type: type, objectID: "", user: user, duration: guests.isEmpty ? 0.5 : 5,
                         error: failed ? "Some guests failed to migrate" : nil)
    }

    private func targetProblem(_ target: String, source: String?) -> HTTPResponse? {
        guard let node = cluster.nodes.first(where: { $0.name == target }) else {
            return fieldFailure(["target": "no such cluster node '\(target)'"])
        }
        guard node.isOnline else { return failure(500, "target node '\(target)' is not online") }
        if target == source { return failure(500, "target is local node.") }
        return nil
    }

    /// Starts the migration task on the source node. Errors Proxmox finds before the task are returned right away;
    /// a local CD/DVD fails the task, as it does in Proxmox.
    private func startMigration(_ guest: DemoCluster.Guest, target: String, online: Bool, withLocalDisks: Bool, user: String) -> HTTPResponse {
        if let problem = targetProblem(target, source: guest.node) { return problem }
        if let problem = migrationProblem(guest, target: target, online: online, withLocalDisks: withLocalDisks) { return failure(500, problem) }
        let isVM = guest.kind == .qemu
        let disks = localDisks(of: guest)
        let cdrom = isVM ? localCDROM(of: guest) : nil
        let wasRunning = guest.isRunning
        return startTask(
            node: guest.node, type: isVM ? "qmigrate" : "vzmigrate", objectID: String(guest.vmid), user: user, duration: 3 + Double(disks.count),
            error: cdrom.map { "can't migrate local disk '\($0)': local cdrom image" }
        ) { moved in
            moved.node = target
            // Containers restart on the target.
            if !isVM, wasRunning { moved.bootedAt = Date() }
        }
    }

    private func migrationProblem(_ guest: DemoCluster.Guest, target: String, online: Bool, withLocalDisks: Bool) -> String? {
        let isVM = guest.kind == .qemu
        if guest.isRunning, !online {
            return isVM ? "can't migrate running VM without --online" : "lxc live migration is currently not implemented"
        }
        if isVM, guest.isRunning, !withLocalDisks, localDisks(of: guest).contains(where: { !$0.isCDROM }) {
            return "can't live migrate attached local disks without with-local-disks option"
        }
        return nil
    }

    private struct LocalDisk {
        var volume: String
        var size: Int64?
        var isCDROM: Bool
    }

    /// Disks of a VM on storage the other nodes cannot reach. Containers report none, as in Proxmox.
    private func localDisks(of guest: DemoCluster.Guest) -> [LocalDisk] {
        guard guest.kind == .qemu else { return [] }
        let diskKey = /^(ide|sata|scsi|virtio|efidisk|tpmstate|unused)\d+$/
        return currentConfig(guest).sorted { $0.key < $1.key }.compactMap { key, value in
            guard key.wholeMatch(of: diskKey) != nil else { return nil }
            let volume = String(value.split(separator: ",").first ?? "")
            guard let storage = volume.split(separator: ":").first.map(String.init), volume.contains(":"),
                  storageConfigs.first(where: { $0.id == storage })?.isShared == false
            else { return nil }
            let options = value.split(separator: ",").dropFirst()
            let size = options.first { $0.hasPrefix("size=") }.flatMap { Self.bytes(String($0.dropFirst(5))) }
            return LocalDisk(volume: volume, size: size, isCDROM: options.contains("media=cdrom"))
        }
    }

    private func localCDROM(of guest: DemoCluster.Guest) -> String? {
        localDisks(of: guest).first { $0.isCDROM && !$0.volume.contains("cloudinit") }?.volume
    }

    private func migrationPreconditions(_ guest: DemoCluster.Guest) -> JSONValue {
        let others = cluster.nodes.filter { $0.name != guest.node }
        let allowed = others.filter(\.isOnline).map { JSONValue.string($0.name) }
        let notAllowed = Dictionary(uniqueKeysWithValues: others.map { ($0.name, JSONValue.object([:])) })
        guard guest.kind == .qemu else {
            return ["running": .int(guest.isRunning ? 1 : 0), "allowed-nodes": .array(allowed), "not-allowed-nodes": .object(notAllowed)]
        }
        let disks: [JSONValue] = localDisks(of: guest).map { disk in
            var entry: [String: JSONValue] = [
                "volid": .string(disk.volume), "cdrom": .int(disk.isCDROM ? 1 : 0), "is_cloudinit": .int(disk.volume.contains("cloudinit") ? 1 : 0),
                "is_unused": 0, "shared": 0,
            ]
            if let size = disk.size { entry["size"] = .int(Int(size)) }
            return .object(entry)
        }
        return [
            "running": .int(guest.isRunning ? 1 : 0), "allowed_nodes": .array(allowed), "not_allowed_nodes": .object(notAllowed),
            "local_disks": .array(disks), "local_resources": [], "mapped-resources": [], "mapped-resource-info": [:],
            "has-dbus-vmstate": 1,
        ]
    }

    /// Bytes of a Proxmox size such as `32G`, `754M` or `4M`.
    private static func bytes(_ size: String) -> Int64? {
        let units: [Character: Int64] = ["K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40]
        guard let unit = size.last, let factor = units[unit], let number = Double(size.dropLast()) else { return Int64(size) }
        return Int64(number * Double(factor))
    }
}
