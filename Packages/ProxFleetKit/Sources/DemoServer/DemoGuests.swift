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
        if let response = handleCreation(method, parts: parts, parameters: parameters, user: user)
            ?? handleStorageConfig(method, parts: parts, parameters: parameters, user: user)
            ?? handleBackupJobs(method, parts: parts, parameters: parameters, user: user)
            ?? handlePools(method, parts: parts, parameters: parameters, user: user)
            ?? handleFirewall(method, parts: parts, parameters: parameters, user: user)
            ?? handleSDN(method, parts: parts, parameters: parameters, user: user)
            ?? handleMappings(method, parts: parts, parameters: parameters, user: user)
            ?? handleAccess(method, parts: parts, parameters: parameters, user: user)
            ?? handleTwoFactorAndRealms(method, parts: parts, parameters: parameters, user: user)
            ?? handleNotifications(method, parts: parts, parameters: parameters, user: user) {
            return response
        }

        switch (method, parts.count) {
        case (.get, 2) where parts == ["cluster", "tasks"]:
            return success(.array(tasks.reversed().map(clusterTaskJSON)))
        case (.get, 2) where parts == ["access", "permissions"]:
            let path = parameters["path"] ?? "/"
            return success(.object([path: .object(Dictionary(uniqueKeysWithValues: privileges(for: user).map { ($0, JSONValue.int(1)) }))]))
        default:
            break
        }

        if parts.count == 3, parts[0] == "nodes", method == .post, parts[2] == "termproxy" {
            return startConsole(.init(kind: .terminal, hostname: parts[1], osName: "Proxmox VE \(cluster.version)", isContainer: false, command: parameters["cmd"]), user: user)
        }
        guard parts.count >= 3, parts[0] == "nodes" else { return nil }
        let node = parts[1]
        if let response = handleStorage(method, node: node, rest: Array(parts.dropFirst(2)), parameters: parameters, user: user) {
            return response
        }
        if let response = handleBackups(method, node: node, rest: Array(parts.dropFirst(2)), parameters: parameters, user: user) {
            return response
        }
        if let response = handleNode(method, node: node, rest: Array(parts.dropFirst(2)), parameters: parameters, user: user) {
            return response
        }

        if parts[2] == "tasks", parts.count == 4, method == .delete {
            guard let index = tasks.firstIndex(where: { $0.upid == parts[3] }) else { return failure(500, "no such task") }
            if tasks[index].user != user, !privileges(for: user).contains("Sys.Modify") {
                return failure(403, "Permission check failed (/nodes/\(node), Sys.Modify)")
            }
            // A stopped task ends now, fails and leaves its guest unchanged.
            if !tasks[index].isFinished(at: Date()) {
                tasks[index].duration = Date().timeIntervalSince(tasks[index].startedAt)
                tasks[index].error = "interrupted by signal"
                tasks[index].apply = nil
                tasks[index].isApplied = true
            }
            return success(nil)
        }
        if parts[2] == "tasks", parts.count == 5 {
            guard let task = tasks.first(where: { $0.upid == parts[3] }) else { return failure(500, "no such task") }
            switch parts[4] {
            case "status": return success(taskStatusJSON(task))
            case "log": return success(.array(taskLog(task).enumerated().map { ["n": .int($0.offset + 1), "t": .string($0.element)] }))
            default: return nil
            }
        }

        switch (method, Array(parts.dropFirst(2))) {
        case (.get, ["capabilities", "qemu", "machines"]):
            return success(.array(["10.0+pve1", "9.2+pve1", "9.0", "8.1"].flatMap { version in
                ["q35", "i440fx"].map { type in ["id": .string("pc-\(type)-\(version)"), "type": .string(type), "version": .string(version)] }
            }))
        case (.get, ["hardware", "pci"]):
            return success(Self.pciDevices)
        case (.get, ["hardware", "usb"]):
            return success(Self.usbDevices)
        case (.get, let path) where path.count == 4 && path[0] == "hardware" && path[1] == "pci" && path[3] == "mdev":
            return success(Self.mediatedDeviceTypes(of: path[2]))
        case (.post, let path) where path.count == 1 && ["startall", "stopall", "suspendall"].contains(path[0]):
            return bulkAction(path[0], node: node, parameters: parameters, user: user)
        case (.get, ["capabilities", "qemu", "cpu"]):
            let models = parameters["arch"] == "aarch64"
                ? ["host", "max", "cortex-a53", "cortex-a57", "cortex-a72", "neoverse-n1"]
                : ["host", "x86-64-v2-AES", "x86-64-v3", "kvm64", "qemu64", "EPYC-Rome", "Skylake-Server"]
            return success(.array(models.map { ["name": .string($0), "vendor": "default", "custom": 0] }))
        default:
            break
        }

        guard parts.count >= 4 else { return nil }
        guard ["qemu", "lxc"].contains(parts[2]), let vmid = Int(parts[3]),
              let index = cluster.guests.firstIndex(where: { $0.vmid == vmid && $0.kind.rawValue == parts[2] })
        else { return failure(500, "Configuration file 'nodes/\(node)/\(parts[2])/\(parts[3]).conf' does not exist") }
        guard cluster.nodes.first(where: { $0.name == node })?.isOnline == true else {
            return failure(595, "Connection refused: node '\(node)' seems to be offline")
        }
        let guest = cluster.guests[index]
        let rest = Array(parts.dropFirst(4))
        if let response = handleLifecycle(method, rest: rest, guest: guest, parameters: parameters, user: user) {
            return response
        }

        switch (method, rest) {
        case (.get, ["status", "current"]):
            return success(statusJSON(guest))
        case (.get, ["config"]):
            return success(.object(currentConfig(guest).mapValues { JSONValue.string($0) }))
        case (.get, ["pending"]):
            return success(pendingJSON(guest))
        case (.post, ["config"]), (.put, ["config"]):
            return updateConfig(guest, parameters: parameters, user: user, asTask: method == .post)
        case (.put, ["resize"]):
            return resize(guest, parameters: parameters, user: user)
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
        case (.post, ["termproxy"]), (.post, ["vncproxy"]):
            guard guest.isRunning else { return failure(500, "\(guest.kind == .qemu ? "VM" : "CT") \(vmid) not running") }
            let isVNC = rest == ["vncproxy"]
            return startConsole(.init(
                kind: isVNC ? .vnc : .terminal, hostname: guest.name, osName: osName(for: guest),
                isContainer: guest.kind == .lxc, vmid: vmid, isWindows: isVNC && guest.name.contains("win")
            ), user: user)
        case (.post, ["move_disk"]), (.post, ["move_volume"]):
            return moveDisk(guest, parameters: parameters, user: user)
        case (.put, ["cloudinit"]):
            return success(nil)
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

    /// Node bulk actions: one task for the node, plus the usual task for every guest it covers.
    private func bulkAction(_ endpoint: String, node: String, parameters: [String: String], user: String) -> HTTPResponse {
        guard cluster.nodes.first(where: { $0.name == node })?.isOnline == true else {
            return failure(595, "Connection refused: node '\(node)' seems to be offline")
        }
        guard privileges(for: user).contains("VM.PowerMgmt") else { return failure(403, "Permission check failed (/, VM.PowerMgmt)") }
        let chosen = parameters["vms"].map { Set($0.split(separator: ",").compactMap { Int($0) }) }
        let guests = cluster.guests.filter { guest in
            guard guest.node == node, !guest.isTemplate, chosen?.contains(guest.vmid) ?? true else { return false }
            switch endpoint {
            case "startall": return !guest.isRunning
            case "stopall": return guest.isRunning
            default: return guest.isRunning && guest.kind == .qemu
            }
        }
        let response = startTask(node: node, type: endpoint, objectID: "", user: user, duration: guests.isEmpty ? 0.5 : 4.5)
        for guest in guests {
            switch endpoint {
            case "startall": _ = startPowerTask("start", guest: guest, todisk: false, user: user)
            case "stopall": _ = startPowerTask("shutdown", guest: guest, todisk: false, user: user)
            default: _ = startPowerTask("suspend", guest: guest, todisk: true, user: user)
            }
        }
        return response
    }

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
                if ["start", "stop", "shutdown", "reboot", "reset"].contains(where: tasks[index].type.hasSuffix), let vmid = Int(tasks[index].objectID) {
                    applyPendingEdits(of: vmid)
                }
            }
        }
    }

    func privileges(for user: String) -> [String] {
        let audit = ["VM.Audit", "VM.Monitor", "Datastore.Audit", "Sys.Audit", "Pool.Audit"]
        if user.hasPrefix("auditor") || user.hasPrefix("limited") { return audit }
        return audit + [
            "VM.PowerMgmt", "VM.Console", "VM.Config.CPU", "VM.Config.Memory", "VM.Config.Disk", "VM.Config.CDROM",
            "VM.Config.Network", "VM.Config.HWType", "VM.Config.Options", "VM.Config.Cloudinit", "VM.Allocate", "VM.Clone",
            "VM.Snapshot", "VM.Snapshot.Rollback", "VM.Backup", "VM.Migrate", "Datastore.AllocateSpace", "Datastore.Allocate", "Datastore.AllocateTemplate",
            "User.Modify", "Group.Allocate", "Permissions.Modify", "Realm.Allocate", "Realm.AllocateUser", "Sys.Modify", "Pool.Allocate", "SDN.Allocate", "SDN.Audit", "Mapping.Audit", "Mapping.Modify", "Sys.PowerMgmt", "Sys.Console",
        ]
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
            "digest": .string(digest(for: guest)),
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
            // Linux VMs have a serial port for the serial console.
            if !guest.name.contains("win") { data["serial0"] = "socket" }
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
            // The media server transcodes on the host's GPU.
            if guest.name == "jellyfin" { data["dev0"] = "/dev/dri/renderD128,gid=104" }
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

    func clusterTaskJSON(_ task: DemoTask) -> JSONValue {
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

    // MARK: - Configuration editing

    private func digest(for guest: DemoCluster.Guest) -> String {
        let revision = configRevisions[guest.vmid] ?? 0
        return String(format: "%08x", guest.vmid) + String(repeating: "0", count: 24) + String(format: "%08x", revision)
    }

    /// Generated configuration with edits applied.
    func currentConfig(_ guest: DemoCluster.Guest) -> [String: String] {
        if var config = createdConfigs[guest.vmid] {
            for (key, value) in configEdits[guest.vmid] ?? [:] { config[key] = value }
            config["digest"] = digest(for: guest)
            return config
        }
        guard case .object(let generated) = configJSON(guest) else { return [:] }
        var config: [String: String] = [:]
        for (key, value) in generated {
            switch value {
            case .string(let text): config[key] = text
            case .int(let number): config[key] = String(number)
            case .double(let number): config[key] = String(number)
            case .bool(let flag): config[key] = flag ? "1" : "0"
            default: break
            }
        }
        for (key, value) in configEdits[guest.vmid] ?? [:] {
            config[key] = value
        }
        return config
    }

    private func pendingJSON(_ guest: DemoCluster.Guest) -> JSONValue {
        let config = currentConfig(guest)
        let pending = pendingEdits[guest.vmid] ?? [:]
        let keys = Set(config.keys).union(pending.keys).subtracting(["digest"])
        return .array(keys.sorted().map { key in
            var item: [String: JSONValue] = ["key": .string(key)]
            if let value = config[key] { item["value"] = .string(value) }
            if let change = pending[key] {
                if let change { item["pending"] = .string(change) } else { item["delete"] = 1 }
            }
            return .object(item)
        })
    }

    private func updateConfig(_ guest: DemoCluster.Guest, parameters: [String: String], user: String, asTask: Bool) -> HTTPResponse {
        guard privileges(for: user).contains("VM.Config.Options") else {
            return failure(403, "Permission check failed (/vms/\(guest.vmid), VM.Config.Options)")
        }
        if let expected = parameters["digest"], expected != digest(for: guest) {
            return failure(500, "checksum mismatch (file change by other user?)")
        }
        var errors: [String: JSONValue] = [:]
        for key in ["cores", "sockets"] {
            if let value = parameters[key], (Int(value) ?? 0) < 1 { errors[key] = "value must have a minimum value of 1" }
        }
        if let value = parameters["memory"], (Int(value) ?? 0) < 16 { errors["memory"] = "value must have a minimum value of 16" }
        if !errors.isEmpty {
            let body: JSONValue = ["data": nil, "success": 0, "status": "400", "message": "Parameter verification failed.", "errors": .object(errors)]
            return HTTPResponse(statusCode: 200, body: body.encoded())
        }

        var changes: [String: String?] = [:]
        for (key, value) in parameters where !["digest", "delete", "revert"].contains(key) {
            changes[key] = .some(allocateVolume(value, key: key, guest: guest))
        }
        let config = currentConfig(guest)
        for key in (parameters["delete"] ?? "").split(separator: ",").map(String.init) {
            changes[key] = .some(nil)
            // Like Proxmox, a detached disk stays as an unused volume until it is deleted.
            if let volume = Self.detachableVolume(key: key, value: config[key]) {
                let unused = (0..<256).map { "unused\($0)" }.first { config[$0] == nil && changes[$0] == nil }
                if let unused { changes[unused] = .some(volume) }
            }
        }
        // Like Proxmox without hotplug for these, a running guest gets them on its next start.
        let coldKeys: Set<String> = ["memory", "cores", "sockets", "cpu", "bios", "machine"]
        for (key, value) in changes {
            if guest.isRunning, coldKeys.contains(key) {
                pendingEdits[guest.vmid, default: [:]][key] = .some(value)
            } else {
                configEdits[guest.vmid, default: [:]][key] = .some(value)
            }
        }
        for key in (parameters["revert"] ?? "").split(separator: ",").map(String.init) {
            pendingEdits[guest.vmid]?[key] = nil
        }
        configRevisions[guest.vmid, default: 0] += 1
        applySummaryFields(of: guest.vmid)
        return asTask ? startConfigTask(guest, user: user) : success(nil)
    }

    private func resize(_ guest: DemoCluster.Guest, parameters: [String: String], user: String) -> HTTPResponse {
        guard let disk = parameters["disk"], let size = parameters["size"], var value = currentConfig(guest)[disk] else {
            return failure(500, "disk does not exist")
        }
        var property = PropertyString(parsing: value)
        let current = Int(property["size"]?.dropLast() ?? "0") ?? 0
        let requested = Int(size.trimmingCharacters(in: CharacterSet(charactersIn: "+G"))) ?? 0
        property["size"] = "\(size.hasPrefix("+") ? current + requested : requested)G"
        value = property.stringValue
        configEdits[guest.vmid, default: [:]][disk] = .some(value)
        configRevisions[guest.vmid, default: 0] += 1
        return startConfigTask(guest, user: user, type: "resize")
    }

    func startConfigTask(_ guest: DemoCluster.Guest, user: String, type: String = "qmconfig") -> HTTPResponse {
        let start = Date()
        let upid = String(format: "UPID:%@:%08X:%08X:%08X:%@:%d:%@:", guest.node, 4000 + tasks.count, 100_000 + tasks.count, Int(start.timeIntervalSince1970), type, guest.vmid, user)
        tasks.append(DemoTask(upid: upid, node: guest.node, type: type, objectID: String(guest.vmid), user: user, startedAt: start, duration: 0.4, error: nil, apply: nil))
        return success(.string(upid))
    }

    /// Keeps the cluster resources in line with edited name, cores and memory.
    private func applySummaryFields(of vmid: Int) {
        guard let index = cluster.guests.firstIndex(where: { $0.vmid == vmid }), let edits = configEdits[vmid] else { return }
        if let name = edits["name"] ?? edits["hostname"], let name { cluster.guests[index].name = name }
        if let cores = edits["cores"], let cores, let value = Int(cores) { cluster.guests[index].cores = value }
        if let memory = edits["memory"], let memory, let value = Double(memory) { cluster.guests[index].memoryGiB = value / 1024 }
    }

    /// Pending changes take effect when a guest starts.
    func applyPendingEdits(of vmid: Int) {
        guard let pending = pendingEdits.removeValue(forKey: vmid) else { return }
        for (key, value) in pending { configEdits[vmid, default: [:]][key] = .some(value) }
        configRevisions[vmid, default: 0] += 1
        applySummaryFields(of: vmid)
    }

    private func mac(for guest: DemoCluster.Guest) -> String {
        String(format: "BC:24:11:%02X:%02X:%02X", guest.vmid % 256, (guest.vmid / 7) % 256, (guest.vmid * 13) % 256)
    }

    private func ipAddress(for guest: DemoCluster.Guest) -> String {
        "10.0.20.\(guest.vmid % 250 + 2)"
    }
}
