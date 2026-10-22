import Foundation
import ProxmoxCore

struct DemoBackup {
    var volume: String
    var vmid: Int
    var kind: DemoCluster.Guest.Kind
    var date: Date
    var size: Int
    var notes: String
    var isProtected: Bool
    /// The guest configuration at backup time; nil for the sample backups, which use the guest's current one.
    var config: [String: String]?
    /// The backup shows up once its task finished.
    var availableAt: Date
}

/// Backups and restores in demo mode, all on the `local` storage.
extension DemoState {
    /// A few backups so the screen is not empty in demo mode.
    static func sampleBackups(for cluster: DemoCluster, now: Date) -> [DemoBackup] {
        let samples: [(vmid: Int, daysAgo: Double, notes: String, isProtected: Bool)] = [
            (100, 1, "home-assistant", false), (100, 8, "Before the 2026.10 update", true),
            (101, 2, "truenas", false), (200, 1, "pihole", false), (202, 3, "jellyfin", false),
        ]
        // Clusters also back up to the Proxmox Backup Server, which allows live restores.
        let backupServerSamples: [(vmid: Int, daysAgo: Double, notes: String, isProtected: Bool)] = cluster.clusterName == nil ? [] : [(100, 0.5, "home-assistant", false)]
        return (samples.map { ($0, "local") } + backupServerSamples.map { ($0, "pbs") }).compactMap { sample, storage in
            guard let guest = cluster.guests.first(where: { $0.vmid == sample.vmid }) else { return nil }
            let date = now.addingTimeInterval(-sample.daysAgo * 86_400 - 3 * 3600)
            return DemoBackup(
                volume: volumeName(vmid: sample.vmid, kind: guest.kind, date: date, storage: storage), vmid: sample.vmid, kind: guest.kind, date: date,
                size: guest.diskGiB * 120_000_000, notes: sample.notes, isProtected: sample.isProtected, config: nil, availableAt: .distantPast
            )
        }
    }

    static func volumeName(vmid: Int, kind: DemoCluster.Guest.Kind, date: Date, storage: String = "local") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        if storage == "pbs" {
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            return "\(storage):backup/\(kind == .qemu ? "vm" : "ct")/\(vmid)/\(formatter.string(from: date))"
        }
        formatter.dateFormat = "yyyy_MM_dd-HH_mm_ss"
        return "\(storage):backup/vzdump-\(kind.rawValue)-\(vmid)-\(formatter.string(from: date)).\(kind == .qemu ? "vma" : "tar").zst"
    }

    /// Finished backups on a storage, as `GET .../content` lists them.
    func backupVolumes(storage: String, vmid: Int?) -> [JSONValue] {
        let now = Date()
        return backups.filter { $0.availableAt <= now && $0.volume.hasPrefix(storage + ":") && (vmid == nil || $0.vmid == vmid) }.map { backup in
            var entry: [String: JSONValue] = [
                "volid": .string(backup.volume), "vmid": .int(backup.vmid), "subtype": .string(backup.kind.rawValue),
                "ctime": .int(Int(backup.date.timeIntervalSince1970)), "size": .int(backup.size), "content": "backup",
                "format": .string(backup.volume.hasPrefix("pbs:") ? (backup.kind == .qemu ? "pbs-vm" : "pbs-ct") : backup.kind == .qemu ? "vma.zst" : "tar.zst"),
            ]
            if !backup.notes.isEmpty { entry["notes"] = .string(backup.notes) }
            if backup.isProtected { entry["protected"] = 1 }
            return .object(entry)
        }
    }

    /// Node-level backup routes: `vzdump`, `extractconfig` and the backup volumes of the storage. nil for other paths.
    func handleBackups(_ method: HTTPMethod, node: String, rest: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        let now = Date()
        switch (method, rest) {
        case (.get, let path) where path.count == 3 && path[0] == "storage" && path[2] == "content" && parameters["content"] == "backup":
            return success(.array(backupVolumes(storage: path[1], vmid: parameters["vmid"].flatMap(Int.init))))

        case (_, let path) where path.count >= 4 && path[0] == "storage" && path[2] == "content":
            // The volume ID contains a slash, so it arrives split over several path segments.
            let volume = path.dropFirst(3).joined(separator: "/")
            guard let index = backups.firstIndex(where: { $0.volume == volume }) else { return nil }
            switch method {
            case .put:
                if let notes = parameters["notes"] { backups[index].notes = notes }
                if let isProtected = parameters["protected"] { backups[index].isProtected = isProtected == "1" }
                return success(nil)
            case .delete:
                let backup = backups[index]
                if !backup.isProtected { backups.remove(at: index) }
                return startTask(node: node, type: "imgdel", objectID: "\(backup.vmid)@local", user: user, duration: 1, error: backup.isProtected ? "backup is protected" : nil)
            default:
                return nil
            }

        case (.get, ["vzdump", "extractconfig"]):
            guard let backup = backups.first(where: { $0.volume == parameters["volume"] }) else { return failure(500, "volume does not exist") }
            let config = backup.config ?? cluster.guests.first { $0.vmid == backup.vmid }.map(currentConfig) ?? [:]
            let text = config.filter { $0.key != "digest" }.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            return success(.string(text + "\n"))

        case (.post, ["vzdump"]):
            return vzdump(node: node, parameters: parameters, user: user, now: now)

        default:
            return nil
        }
    }

    /// Backs up one guest (`vmid`), several, every guest of the node (`all`, with `exclude`) or a pool's guests on the node.
    private func vzdump(node: String, parameters: [String: String], user: String, now: Date) -> HTTPResponse {
        let storage = parameters["storage"] ?? "local"
        guard storageConfigs.contains(where: { $0.id == storage && $0.content.contains("backup") && $0.isAvailable(on: node) }) else {
            return failure(500, "storage '\(storage)' does not support backups")
        }
        let ids: (String?) -> Set<Int> = { text in Set((text ?? "").split(separator: ",").compactMap { Int($0) }) }
        var guests: [DemoCluster.Guest]
        if parameters["all"] == "1" {
            let excluded = ids(parameters["exclude"])
            guests = cluster.guests.filter { $0.node == node && !excluded.contains($0.vmid) }
        } else if let pool = parameters["pool"] {
            guests = cluster.guests.filter { $0.node == node && poolGuests(pool).contains($0.vmid) }
        } else {
            let wanted = ids(parameters["vmid"])
            guard !wanted.isEmpty, cluster.guests.contains(where: { wanted.contains($0.vmid) }) else { return failure(500, "unable to find guest") }
            guests = cluster.guests.filter { wanted.contains($0.vmid) && $0.node == node }
        }
        guard !guests.isEmpty else { return failure(500, "No guests selected on node '\(node)'") }
        for guest in guests where !privileges(for: user).contains("VM.Backup") {
            return failure(403, "Permission check failed (/vms/\(guest.vmid), VM.Backup)")
        }
        let duration = 4 * TimeInterval(guests.count)
        for (index, guest) in guests.enumerated() {
            var notes = parameters["notes-template"] ?? ""
            for (variable, value) in ["guestname": guest.name, "vmid": String(guest.vmid), "node": guest.node, "cluster": cluster.clusterName ?? ""] {
                notes = notes.replacingOccurrences(of: "{{\(variable)}}", with: value)
            }
            var config = currentConfig(guest)
            config["digest"] = nil
            let date = now.addingTimeInterval(TimeInterval(index))
            backups.append(DemoBackup(
                volume: Self.volumeName(vmid: guest.vmid, kind: guest.kind, date: date, storage: storage), vmid: guest.vmid, kind: guest.kind, date: date,
                size: guest.diskGiB * 120_000_000, notes: notes, isProtected: parameters["protected"] == "1", config: config,
                availableAt: now.addingTimeInterval(4 * TimeInterval(index + 1))
            ))
        }
        return startTask(node: node, type: "vzdump", objectID: guests.count == 1 ? String(guests[0].vmid) : "", user: user, duration: duration)
    }

    /// `POST /nodes/{node}/qemu` with `archive`, or `/lxc` with `restore=1`: over the existing guest with `force`, or as a new one.
    func restoreBackup(_ volume: String, kind: DemoCluster.Guest.Kind, node: String, parameters: [String: String], user: String) -> HTTPResponse {
        guard let backup = backups.first(where: { $0.volume == volume }) else { return failure(500, "volume '\(volume)' does not exist") }
        guard let vmid = parameters["vmid"].flatMap(Int.init), vmid >= 100 else { return fieldFailure(["vmid": "value must have a minimum value of 100"]) }
        if kind == .lxc, parameters["storage"] == nil {
            return fieldFailure(["storage": "storage 'local' does not support container directories"])
        }
        var config = backup.config ?? cluster.guests.first { $0.vmid == backup.vmid }.map(currentConfig) ?? [:]
        config["digest"] = nil
        config = Self.movingDisks(of: config, from: backup.vmid, to: vmid, storage: parameters["storage"])
        let nameKey = kind == .qemu ? "name" : "hostname"
        // Overrides of the restore dialog replace the backup's values.
        for key in [nameKey, "cores", "memory"] + (kind == .qemu ? ["sockets"] : ["unprivileged"]) {
            if let value = parameters[key] { config[key] = value }
        }
        let name = config[nameKey] ?? "restored-\(vmid)"

        if let index = cluster.guests.firstIndex(where: { $0.vmid == vmid }) {
            guard parameters["force"] == "1" else { return fieldFailure(["vmid": "\(kind == .qemu ? "VM" : "CT") \(vmid) already exists"]) }
            guard privileges(for: user).contains("VM.Backup") else { return failure(403, "Permission check failed (/vms/\(vmid), VM.Backup)") }
            guard !cluster.guests[index].isRunning else { return failure(500, "unable to restore \(kind == .qemu ? "VM" : "CT") \(vmid) - it is running") }
            cluster.guests[index].name = name
            cluster.guests[index].isTemplate = config["template"] == "1"
        } else {
            guard privileges(for: user).contains("VM.Allocate") else { return failure(403, "Permission check failed (/vms/\(vmid), VM.Allocate)") }
            guard let original = cluster.guests.first(where: { $0.vmid == backup.vmid }) ?? cluster.guests.first(where: { $0.kind == kind }) else {
                return failure(500, "unable to restore")
            }
            var guest = original
            guest.vmid = vmid
            guest.name = name
            guest.node = node
            guest.isRunning = false
            guest.isPaused = false
            guest.bootedAt = nil
            guest.isTemplate = config["template"] == "1"
            cluster.guests.append(guest)
        }
        createdConfigs[vmid] = config
        configEdits[vmid] = nil
        pendingEdits[vmid] = nil
        configRevisions[vmid, default: 0] += 1
        snapshots[vmid] = nil
        currentSnapshot[vmid] = nil
        if let cores = parameters["cores"].flatMap(Int.init), let index = cluster.guests.firstIndex(where: { $0.vmid == vmid }) {
            cluster.guests[index].cores = cores * (parameters["sockets"].flatMap(Int.init) ?? 1)
        }
        // A live restore starts the VM right away while the disks are restored in the background.
        let start = parameters["start"] == "1" || parameters["live-restore"] == "1"
        return startTask(node: node, type: kind == .qemu ? "qmrestore" : "vzrestore", objectID: String(vmid), user: user, duration: 3) { guest in
            if start {
                guest.isRunning = true
                guest.bootedAt = Date()
            }
        }
    }
}
