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
        return samples.compactMap { sample in
            guard let guest = cluster.guests.first(where: { $0.vmid == sample.vmid }) else { return nil }
            let date = now.addingTimeInterval(-sample.daysAgo * 86_400 - 3 * 3600)
            return DemoBackup(
                volume: volumeName(vmid: sample.vmid, kind: guest.kind, date: date), vmid: sample.vmid, kind: guest.kind, date: date,
                size: guest.diskGiB * 120_000_000, notes: sample.notes, isProtected: sample.isProtected, config: nil, availableAt: .distantPast
            )
        }
    }

    static func volumeName(vmid: Int, kind: DemoCluster.Guest.Kind, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy_MM_dd-HH_mm_ss"
        return "local:backup/vzdump-\(kind.rawValue)-\(vmid)-\(formatter.string(from: date)).\(kind == .qemu ? "vma" : "tar").zst"
    }

    /// Node-level backup routes: `vzdump`, `extractconfig` and the backup volumes of the storage. nil for other paths.
    func handleBackups(_ method: HTTPMethod, node: String, rest: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        let now = Date()
        switch (method, rest) {
        case (.get, let path) where path.count == 3 && path[0] == "storage" && path[2] == "content" && parameters["content"] == "backup":
            let vmid = parameters["vmid"].flatMap(Int.init)
            let visible = backups.filter { $0.availableAt <= now && $0.volume.hasPrefix(path[1] + ":") && (vmid == nil || $0.vmid == vmid) }
            return success(.array(visible.map { backup in
                var entry: [String: JSONValue] = [
                    "volid": .string(backup.volume), "vmid": .int(backup.vmid), "subtype": .string(backup.kind.rawValue),
                    "ctime": .int(Int(backup.date.timeIntervalSince1970)), "size": .int(backup.size), "content": "backup",
                    "format": .string(backup.kind == .qemu ? "vma.zst" : "tar.zst"),
                ]
                if !backup.notes.isEmpty { entry["notes"] = .string(backup.notes) }
                if backup.isProtected { entry["protected"] = 1 }
                return .object(entry)
            }))

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
            guard let vmid = parameters["vmid"].flatMap(Int.init), let guest = cluster.guests.first(where: { $0.vmid == vmid }) else {
                return failure(500, "unable to find guest")
            }
            guard privileges(for: user).contains("VM.Backup") else { return failure(403, "Permission check failed (/vms/\(vmid), VM.Backup)") }
            guard parameters["storage"] == "local" else { return failure(500, "storage '\(parameters["storage"] ?? "")' does not support backups") }
            let duration: TimeInterval = 4
            var notes = parameters["notes-template"] ?? ""
            for (variable, value) in ["guestname": guest.name, "vmid": String(vmid), "node": guest.node, "cluster": cluster.clusterName ?? ""] {
                notes = notes.replacingOccurrences(of: "{{\(variable)}}", with: value)
            }
            var config = currentConfig(guest)
            config["digest"] = nil
            backups.append(DemoBackup(
                volume: Self.volumeName(vmid: vmid, kind: guest.kind, date: now), vmid: vmid, kind: guest.kind, date: now,
                size: guest.diskGiB * 120_000_000, notes: notes, isProtected: parameters["protected"] == "1", config: config,
                availableAt: now.addingTimeInterval(duration)
            ))
            return startTask(node: guest.node, type: "vzdump", objectID: String(vmid), user: user, duration: duration)

        default:
            return nil
        }
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
        let start = parameters["start"] == "1"
        return startTask(node: node, type: kind == .qemu ? "qmrestore" : "vzrestore", objectID: String(vmid), user: user, duration: 3) { guest in
            if start {
                guest.isRunning = true
                guest.bootedAt = Date()
            }
        }
    }
}
