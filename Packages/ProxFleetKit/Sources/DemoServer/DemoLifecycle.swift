import Foundation
import ProxmoxCore

struct DemoSnapshot {
    var name: String
    var description: String
    var date: Date
    var parent: String?
    var includesRAM: Bool
}

/// Snapshots, clones, templates and deletion of guests in demo mode.
extension DemoState {
    /// Returns nil for paths this part does not handle.
    func handleLifecycle(_ method: HTTPMethod, rest: [String], guest: DemoCluster.Guest, parameters: [String: String], user: String) -> HTTPResponse? {
        let isVM = guest.kind == .qemu
        let prefix = isVM ? "qm" : "vz"
        let label = isVM ? "VM" : "CT"
        let allowed = privileges(for: user)

        switch (method, rest) {
        case (.get, ["snapshot"]):
            var entries: [JSONValue] = (snapshots[guest.vmid] ?? []).map { snapshot in
                var entry: [String: JSONValue] = [
                    "name": .string(snapshot.name), "description": .string(snapshot.description + "\n"),
                    "snaptime": .int(Int(snapshot.date.timeIntervalSince1970)),
                ]
                if let parent = snapshot.parent { entry["parent"] = .string(parent) }
                if snapshot.includesRAM { entry["vmstate"] = 1 }
                return .object(entry)
            }
            var current: [String: JSONValue] = ["name": "current", "description": "You are here!", "running": .int(guest.isRunning ? 1 : 0)]
            if let parent = currentSnapshot[guest.vmid] { current["parent"] = .string(parent) }
            entries.append(.object(current))
            return success(.array(entries))

        case (.post, ["snapshot"]):
            guard allowed.contains("VM.Snapshot") else { return failure(403, "Permission check failed (/vms/\(guest.vmid), VM.Snapshot)") }
            guard let name = parameters["snapname"] else { return fieldFailure(["snapname": "property is missing and it is not optional"]) }
            guard name != "current", !(snapshots[guest.vmid] ?? []).contains(where: { $0.name == name }) else {
                return failure(500, "snapshot name '\(name)' already used")
            }
            let includesRAM = isVM && parameters["vmstate"] == "1" && guest.isRunning
            snapshots[guest.vmid, default: []].append(DemoSnapshot(
                name: name, description: parameters["description"] ?? "", date: Date(), parent: currentSnapshot[guest.vmid], includesRAM: includesRAM
            ))
            currentSnapshot[guest.vmid] = name
            return startTask(node: guest.node, type: prefix + "snapshot", objectID: String(guest.vmid), user: user, duration: includesRAM ? 3 : 1.5)

        case (.put, let path) where path.count == 3 && path[0] == "snapshot" && path[2] == "config":
            guard let index = snapshots[guest.vmid]?.firstIndex(where: { $0.name == path[1] }) else { return failure(500, "snapshot '\(path[1])' does not exist") }
            snapshots[guest.vmid]?[index].description = parameters["description"] ?? ""
            return success(nil)

        case (.post, let path) where path.count == 3 && path[0] == "snapshot" && path[2] == "rollback":
            guard allowed.contains("VM.Snapshot") || allowed.contains("VM.Snapshot.Rollback") else {
                return failure(403, "Permission check failed (/vms/\(guest.vmid), VM.Snapshot.Rollback)")
            }
            guard let snapshot = snapshots[guest.vmid]?.first(where: { $0.name == path[1] }) else { return failure(500, "snapshot '\(path[1])' does not exist") }
            currentSnapshot[guest.vmid] = snapshot.name
            let start = parameters["start"] == "1"
            // Like Proxmox: the guest ends up stopped unless the snapshot holds the memory or a start was asked for.
            let running = snapshot.includesRAM || start
            return startTask(node: guest.node, type: prefix + "rollback", objectID: String(guest.vmid), user: user, duration: 2) { guest in
                guest.isRunning = running
                guest.isPaused = false
                if running { guest.bootedAt = Date() }
            }

        case (.delete, let path) where path.count == 2 && path[0] == "snapshot":
            guard allowed.contains("VM.Snapshot") else { return failure(403, "Permission check failed (/vms/\(guest.vmid), VM.Snapshot)") }
            guard let snapshot = snapshots[guest.vmid]?.first(where: { $0.name == path[1] }) else { return failure(500, "snapshot '\(path[1])' does not exist") }
            snapshots[guest.vmid]?.removeAll { $0.name == snapshot.name }
            for index in (snapshots[guest.vmid] ?? []).indices where snapshots[guest.vmid]?[index].parent == snapshot.name {
                snapshots[guest.vmid]?[index].parent = snapshot.parent
            }
            if currentSnapshot[guest.vmid] == snapshot.name { currentSnapshot[guest.vmid] = snapshot.parent }
            return startTask(node: guest.node, type: prefix + "delsnapshot", objectID: String(guest.vmid), user: user, duration: 1.5)

        case (.post, ["clone"]):
            return clone(guest, parameters: parameters, user: user)

        case (.post, ["template"]):
            guard allowed.contains("VM.Allocate") else { return failure(403, "Permission check failed (/vms/\(guest.vmid), VM.Allocate)") }
            guard !guest.isRunning else { return failure(500, "\(label) \(guest.vmid) is running") }
            makeTemplate(guest.vmid)
            // Like Proxmox, containers answer without a task.
            return isVM ? startTask(node: guest.node, type: "qmtemplate", objectID: String(guest.vmid), user: user, duration: 1) : success(nil)

        case (.delete, []):
            guard allowed.contains("VM.Allocate") else { return failure(403, "Permission check failed (/vms/\(guest.vmid), VM.Allocate)") }
            guard !guest.isRunning else {
                return failure(500, isVM ? "VM \(guest.vmid) is running - destroy failed" : "unable to destroy CT \(guest.vmid) - container is running")
            }
            cluster.guests.removeAll { $0.vmid == guest.vmid }
            configEdits[guest.vmid] = nil
            pendingEdits[guest.vmid] = nil
            createdConfigs[guest.vmid] = nil
            snapshots[guest.vmid] = nil
            currentSnapshot[guest.vmid] = nil
            return startTask(node: guest.node, type: prefix + "destroy", objectID: String(guest.vmid), user: user, duration: 1.5)

        default:
            return nil
        }
    }

    private func clone(_ source: DemoCluster.Guest, parameters: [String: String], user: String) -> HTTPResponse {
        guard privileges(for: user).contains("VM.Clone") else { return failure(403, "Permission check failed (/vms/\(source.vmid), VM.Clone)") }
        guard let newID = parameters["newid"].flatMap(Int.init), newID >= 100 else {
            return fieldFailure(["newid": "value must have a minimum value of 100"])
        }
        guard !cluster.guests.contains(where: { $0.vmid == newID }) else { return fieldFailure(["newid": "VM \(newID) already exists"]) }
        if parameters["full"] == "0", !source.isTemplate { return failure(500, "Linked clone feature is not supported for running or non-template guests") }
        let node = parameters["target"] ?? source.node
        guard cluster.nodes.first(where: { $0.name == node })?.isOnline == true else {
            return failure(595, "Connection refused: node '\(node)' seems to be offline")
        }

        let isVM = source.kind == .qemu
        let nameKey = isVM ? "name" : "hostname"
        let name = parameters[nameKey] ?? (isVM ? "Copy-of-VM-\(source.name)" : source.name)
        var copy = source
        copy.vmid = newID
        copy.name = name
        copy.node = node
        copy.isRunning = false
        copy.isPaused = false
        copy.isTemplate = false
        copy.bootedAt = nil
        cluster.guests.append(copy)

        // The configuration of the source, with the new name and disks of the clone.
        var config = currentConfig(source)
        config["digest"] = nil
        config["template"] = nil
        config[nameKey] = name
        createdConfigs[newID] = Self.movingDisks(of: config, from: source.vmid, to: newID, storage: parameters["full"] == "0" ? nil : parameters["storage"])
        return startTask(node: source.node, type: isVM ? "qmclone" : "vzclone", objectID: String(source.vmid), user: user, duration: 2.5)
    }

    /// A configuration with its disks renamed for another guest, optionally on another storage. Unused volumes are dropped.
    static func movingDisks(of config: [String: String], from oldID: Int, to newID: Int, storage: String?) -> [String: String] {
        var config = config.filter { !$0.key.hasPrefix("unused") }
        for (key, value) in config where isDiskKey(key) {
            var property = PropertyString(parsing: value)
            guard property["media"] != "cdrom", let volume = property.defaultValue, let colon = volume.firstIndex(of: ":") else { continue }
            let file = volume[volume.index(after: colon)...]
                .replacingOccurrences(of: "base-\(oldID)-", with: "vm-\(newID)-")
                .replacingOccurrences(of: "vm-\(oldID)-", with: "vm-\(newID)-")
            property.items[0].value = "\(storage ?? String(volume[..<colon])):\(file)"
            config[key] = property.stringValue
        }
        return config
    }

    private func makeTemplate(_ vmid: Int) {
        guard let index = cluster.guests.firstIndex(where: { $0.vmid == vmid }) else { return }
        cluster.guests[index].isTemplate = true
        configEdits[vmid, default: [:]]["template"] = .some("1")
        configRevisions[vmid, default: 0] += 1
    }
}
