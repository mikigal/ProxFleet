import Foundation
import ProxmoxCore

/// A task in demo mode. It finishes `duration` seconds after it started, and only then changes the guest.
struct DemoTask {
    var upid: String
    var node: String
    var type: String
    var objectID: String
    var user: String
    var startedAt: Date
    var duration: TimeInterval
    /// nil for success, otherwise the error message.
    var error: String?
    var apply: (@Sendable (inout DemoCluster.Guest) -> Void)?
    var isApplied = false

    func isFinished(at date: Date) -> Bool { date.timeIntervalSince(startedAt) >= duration }
}

extension DemoState {
    /// Routes for guests, tasks and permissions. Returns nil for unknown paths.
    func handleGuestOrTask(_ method: HTTPMethod, path: String, parameters: [String: String], user: String) -> HTTPResponse? {
        settleTasks()
        let parts = path.split(separator: "/").map(String.init)

        switch (method, parts.count) {
        case (.get, 2) where parts == ["cluster", "tasks"]:
            return success(.array(tasks.reversed().map(clusterTaskJSON)))
        case (.get, 2) where parts == ["access", "permissions"]:
            let path = parameters["path"] ?? "/"
            return success(.object([path: .object(Dictionary(uniqueKeysWithValues: privileges(for: user).map { ($0, JSONValue.int(1)) }))]))
        default:
            break
        }

        guard parts.count >= 4, parts[0] == "nodes" else { return nil }
        let node = parts[1]

        if parts[2] == "tasks", parts.count == 5 {
            guard let task = tasks.first(where: { $0.upid == parts[3] }) else { return failure(500, "no such task") }
            switch parts[4] {
            case "status": return success(taskStatusJSON(task))
            case "log": return success(.array(taskLog(task).enumerated().map { ["n": .int($0.offset + 1), "t": .string($0.element)] }))
            default: return nil
            }
        }

        guard ["qemu", "lxc"].contains(parts[2]), let vmid = Int(parts[3]),
              let index = cluster.guests.firstIndex(where: { $0.vmid == vmid && $0.kind.rawValue == parts[2] })
        else { return failure(500, "Configuration file 'nodes/\(node)/\(parts[2])/\(parts[3]).conf' does not exist") }
        guard cluster.nodes.first(where: { $0.name == node })?.isOnline == true else {
            return failure(595, "Connection refused: node '\(node)' seems to be offline")
        }
        let guest = cluster.guests[index]
        let rest = Array(parts.dropFirst(4))

        switch (method, rest) {
        case (.get, ["status", "current"]):
            return success(statusJSON(guest))
        case (.get, ["config"]):
            return success(configJSON(guest))
        case (.get, ["rrddata"]):
            return success(rrdJSON(guest, timeframe: parameters["timeframe"] ?? "hour"))
        case (.get, ["agent", "network-get-interfaces"]):
            guard guest.isRunning, !guest.isPaused else { return failure(500, "VM \(vmid) is not running") }
            return success(["result": .array([
                ["name": "lo", "hardware-address": "00:00:00:00:00:00", "ip-addresses": [["ip-address": "127.0.0.1", "ip-address-type": "ipv4", "prefix": 8]]],
                ["name": "ens18", "hardware-address": .string(mac(for: guest).lowercased()), "ip-addresses": [
                    ["ip-address": .string(ipAddress(for: guest)), "ip-address-type": "ipv4", "prefix": 24],
                ]],
            ])])
        case (.get, ["interfaces"]):
            guard guest.isRunning else { return failure(500, "CT \(vmid) not running") }
            return success(.array([
                ["name": "eth0", "hwaddr": .string(mac(for: guest).lowercased()), "ip-addresses": [
                    ["ip-address": .string(ipAddress(for: guest)), "ip-address-type": "inet", "prefix": "24"],
                ]],
            ]))
        case (.post, let action) where action.count == 2 && action[0] == "status":
            guard privileges(for: user).contains("VM.PowerMgmt") else {
                return failure(403, "Permission check failed (/vms/\(vmid), VM.PowerMgmt)")
            }
            return startPowerTask(action[1], guest: guest, todisk: parameters["todisk"] == "1", user: user)
        default:
            return nil
        }
    }

    // MARK: - Power

    private func startPowerTask(_ action: String, guest: DemoCluster.Guest, todisk: Bool, user: String) -> HTTPResponse {
        let isVM = guest.kind == .qemu
        let prefix = isVM ? "qm" : "vz"
        let label = isVM ? "VM" : "CT"
        var error: String?
        var duration: TimeInterval = 1.5
        let type: String
        let apply: @Sendable (inout DemoCluster.Guest) -> Void

        switch action {
        case "start":
            type = prefix + "start"
            if guest.isRunning { error = "\(label) \(guest.vmid) already running" }
            apply = { $0.isRunning = true; $0.isPaused = false; $0.bootedAt = Date() }
        case "shutdown":
            type = prefix + "shutdown"
            duration = 3
            if !guest.isRunning { error = "\(label) \(guest.vmid) not running" }
            apply = { $0.isRunning = false; $0.isPaused = false }
        case "stop":
            type = prefix + "stop"
            if !guest.isRunning { error = "\(label) \(guest.vmid) not running" }
            apply = { $0.isRunning = false; $0.isPaused = false }
        case "reboot", "reset":
            if action == "reset" && !isVM { return failure(501, "Method 'POST status/reset' not implemented") }
            type = prefix + action
            duration = 3
            if !guest.isRunning { error = "\(label) \(guest.vmid) not running" }
            apply = { $0.bootedAt = Date() }
        case "suspend" where isVM:
            type = todisk ? "qmsuspend" : "qmpause"
            duration = todisk ? 4 : 1
            if !guest.isRunning { error = "VM \(guest.vmid) not running" }
            if todisk {
                apply = { $0.isRunning = false; $0.isPaused = false }
            } else {
                apply = { $0.isPaused = true }
            }
        case "resume" where isVM:
            type = "qmresume"
            duration = 1
            if !guest.isPaused { error = "VM \(guest.vmid) not paused" }
            apply = { $0.isPaused = false }
        default:
            return failure(501, "Method 'POST status/\(action)' is not available in demo mode")
        }

        let start = Date()
        let upid = String(format: "UPID:%@:%08X:%08X:%08X:%@:%d:%@:", guest.node, 4000 + tasks.count, 100_000 + tasks.count, Int(start.timeIntervalSince1970), type, guest.vmid, user)
        tasks.append(DemoTask(upid: upid, node: guest.node, type: type, objectID: String(guest.vmid), user: user, startedAt: start, duration: duration, error: error, apply: error == nil ? apply : nil))
        if tasks.count > 100 { tasks.removeFirst(tasks.count - 100) }
        return success(.string(upid))
    }

    /// Applies the effect of every task that finished since the last request.
    private func settleTasks() {
        let now = Date()
        for index in tasks.indices where !tasks[index].isApplied && tasks[index].isFinished(at: now) {
            tasks[index].isApplied = true
            if let apply = tasks[index].apply, let guestIndex = cluster.guests.firstIndex(where: { String($0.vmid) == tasks[index].objectID }) {
                apply(&cluster.guests[guestIndex])
            }
        }
    }

    private func privileges(for user: String) -> [String] {
        let audit = ["VM.Audit", "VM.Monitor", "Datastore.Audit", "Sys.Audit", "Pool.Audit"]
        if user.hasPrefix("auditor") || user.hasPrefix("limited") { return audit }
        return audit + ["VM.PowerMgmt", "VM.Console", "VM.Config.CPU", "VM.Config.Memory", "VM.Config.Disk", "VM.Config.Network", "VM.Config.Options", "VM.Allocate", "VM.Clone", "VM.Snapshot", "VM.Backup", "Sys.Modify", "Sys.PowerMgmt", "Sys.Console"]
    }

    // MARK: - JSON

    func uptime(of guest: DemoCluster.Guest) -> Int {
        if let bootedAt = guest.bootedAt { return Int(Date().timeIntervalSince(bootedAt)) }
        return 86_400 * (guest.vmid % 9 + 1) + Int(Date().timeIntervalSince(started))
    }

    private func statusJSON(_ guest: DemoCluster.Guest) -> JSONValue {
        let gib = 1_073_741_824.0
        let running = guest.isRunning
        let elapsed = Date().timeIntervalSince(started)
        var data: [String: JSONValue] = [
            "vmid": .int(guest.vmid), "name": .string(guest.name), "status": running ? "running" : "stopped",
            "cpus": .int(guest.cores), "maxmem": .int(Int(guest.memoryGiB * gib)), "maxdisk": .int(Int(Double(guest.diskGiB) * gib)),
            "cpu": .double(running && !guest.isPaused ? Self.load(seed: guest.vmid, elapsed: elapsed, base: 0.08, swing: 0.06) : 0),
            "mem": .int(running ? Int(guest.memoryGiB * gib * 0.6) : 0),
            "disk": .int(guest.kind == .lxc ? Int(Double(guest.diskGiB) * gib * 0.35) : 0),
            "netin": .int(running ? 48_000_000 + guest.vmid * 1000 : 0), "netout": .int(running ? 12_000_000 + guest.vmid * 700 : 0),
            "diskread": .int(running ? 820_000_000 : 0), "diskwrite": .int(running ? 310_000_000 : 0),
            "uptime": .int(running ? uptime(of: guest) : 0), "ha": ["managed": 0],
        ]
        if !guest.tags.isEmpty { data["tags"] = .string(guest.tags.joined(separator: ";")) }
        if guest.kind == .qemu {
            data["qmpstatus"] = .string(running ? (guest.isPaused ? "paused" : "running") : "stopped")
            data["agent"] = 1
            if running {
                data["running-machine"] = "pc-q35-10.0+pve1"
                data["running-qemu"] = "10.0.2"
            }
        } else {
            data["type"] = "lxc"
            data["maxswap"] = .int(536_870_912)
            data["swap"] = 0
        }
        if guest.isTemplate { data["template"] = 1 }
        return .object(data)
    }

    private func configJSON(_ guest: DemoCluster.Guest) -> JSONValue {
        let memory = Int(guest.memoryGiB * 1024)
        var data: [String: JSONValue] = [
            "cores": .int(guest.cores), "memory": .string(String(memory)),
            "digest": .string(String(repeating: String(guest.vmid % 10), count: 40)),
        ]
        if !guest.tags.isEmpty { data["tags"] = .string(guest.tags.joined(separator: ";")) }
        if guest.isTemplate { data["template"] = 1 }
        if guest.kind == .qemu {
            data["name"] = .string(guest.name)
            data["ostype"] = guest.name.contains("win") ? "win11" : "l26"
            data["scsihw"] = "virtio-scsi-single"
            data["scsi0"] = .string("local-lvm:vm-\(guest.vmid)-disk-0,iothread=1,size=\(guest.diskGiB)G")
            data["ide2"] = "local:iso/debian-13.1.0-amd64-netinst.iso,media=cdrom,size=754M"
            data["net0"] = .string("virtio=\(mac(for: guest)),bridge=vmbr0,firewall=1")
            data["boot"] = "order=scsi0;ide2;net0"
            data["agent"] = "1"
            data["cpu"] = "x86-64-v2-AES"
            data["onboot"] = guest.tags.contains("prod") ? 1 : 0
            if guest.name.contains("win") {
                data["bios"] = "ovmf"
                data["machine"] = "pc-q35-10.0"
                data["efidisk0"] = .string("local-lvm:vm-\(guest.vmid)-disk-1,efitype=4m,pre-enrolled-keys=1,size=4M")
                data["tpmstate0"] = .string("local-lvm:vm-\(guest.vmid)-disk-2,size=4M,version=v2.0")
            }
        } else {
            data["hostname"] = .string(guest.name)
            data["ostype"] = "debian"
            data["arch"] = "amd64"
            data["swap"] = 512
            data["unprivileged"] = 1
            data["rootfs"] = .string("local-lvm:vm-\(guest.vmid)-disk-0,size=\(guest.diskGiB)G")
            data["net0"] = .string("name=eth0,bridge=vmbr0,hwaddr=\(mac(for: guest)),ip=dhcp,type=veth")
            data["onboot"] = guest.tags.contains("prod") ? 1 : 0
        }
        return .object(data)
    }

    private func rrdJSON(_ guest: DemoCluster.Guest, timeframe: String) -> JSONValue {
        let step: TimeInterval = ["day": 1800, "week": 10_800, "month": 43_200, "year": 604_800][timeframe] ?? 60
        let now = Date().timeIntervalSince1970
        let end = (now / step).rounded(.down) * step
        let gib = 1_073_741_824.0
        return .array((0..<70).map { index in
            let time = end - Double(69 - index) * step
            guard guest.isRunning || index < 40 else { return ["time": .int(Int(time))] }
            let wave = sin(time / (step * 9) + Double(guest.vmid)) * 0.5 + 0.5
            return [
                "time": .int(Int(time)), "maxcpu": .int(guest.cores), "maxmem": .double(guest.memoryGiB * gib),
                "cpu": .double(0.04 + 0.18 * wave), "mem": .double(guest.memoryGiB * gib * (0.45 + 0.2 * wave)),
                "netin": .double(2_000 + 40_000 * wave), "netout": .double(800 + 9_000 * (1 - wave)),
                "diskread": .double(10_000 * wave), "diskwrite": .double(25_000 * (1 - wave)),
            ]
        })
    }

    private func taskStatusJSON(_ task: DemoTask) -> JSONValue {
        let finished = task.isFinished(at: Date())
        var data: [String: JSONValue] = [
            "upid": .string(task.upid), "node": .string(task.node), "type": .string(task.type), "id": .string(task.objectID),
            "user": .string(task.user), "starttime": .int(Int(task.startedAt.timeIntervalSince1970)),
            "status": finished ? "stopped" : "running", "pid": 4242, "pstart": 100_000,
        ]
        if finished { data["exitstatus"] = .string(task.error ?? "OK") }
        return .object(data)
    }

    private func clusterTaskJSON(_ task: DemoTask) -> JSONValue {
        var data: [String: JSONValue] = [
            "upid": .string(task.upid), "node": .string(task.node), "type": .string(task.type), "id": .string(task.objectID),
            "user": .string(task.user), "starttime": .int(Int(task.startedAt.timeIntervalSince1970)),
        ]
        if task.isFinished(at: Date()) {
            data["endtime"] = .int(Int(task.startedAt.addingTimeInterval(task.duration).timeIntervalSince1970))
            data["status"] = .string(task.error ?? "OK")
        }
        return .object(data)
    }

    private func taskLog(_ task: DemoTask) -> [String] {
        guard task.isFinished(at: Date()) else { return [] }
        if let error = task.error { return ["TASK ERROR: \(error)"] }
        return ["TASK OK"]
    }

    private func mac(for guest: DemoCluster.Guest) -> String {
        String(format: "BC:24:11:%02X:%02X:%02X", guest.vmid % 256, (guest.vmid / 7) % 256, (guest.vmid * 13) % 256)
    }

    private func ipAddress(for guest: DemoCluster.Guest) -> String {
        "10.0.20.\(guest.vmid % 250 + 2)"
    }
}
