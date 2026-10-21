import Foundation
import ProxmoxCore

/// Node status, history, services, packages, journal, tasks and power in demo mode.
extension DemoState {
    static let availableUpdates: [(package: String, title: String, old: String, new: String)] = [
        ("pve-manager", "Proxmox VE: management tools and web interface", "9.0.10", "9.0.11"),
        ("proxmox-widget-toolkit", "Core widgets and libraries for ExtJS", "5.0.5", "5.0.6"),
    ]

    private static let serviceList: [(name: String, description: String)] = [
        ("chrony", "chrony, an NTP client/server"), ("corosync", "Corosync Cluster Engine"), ("cron", "Regular background program processing daemon"),
        ("ksmtuned", "Kernel Samepage Merging (KSM) Tuning Daemon"), ("lxcfs", "FUSE filesystem for LXC"),
        ("postfix", "Postfix Mail Transport Agent (main/default instance)"), ("proxmox-firewall", "Proxmox nftables firewall"),
        ("pve-cluster", "The Proxmox VE cluster filesystem"), ("pve-firewall", "Proxmox VE firewall"),
        ("pve-ha-crm", "PVE Cluster HA Resource Manager Daemon"), ("pve-ha-lrm", "PVE Local HA Resource Manager Daemon"),
        ("pvedaemon", "PVE API Daemon"), ("pveproxy", "PVE API Proxy Server"), ("pvescheduler", "Proxmox VE scheduler"),
        ("pvestatd", "PVE Status Daemon"), ("spiceproxy", "PVE SPICE Proxy Server"), ("sshd", "OpenBSD Secure Shell server"),
        ("systemd-journald", "Journal Service"), ("systemd-timesyncd", "Network Time Synchronization"),
    ]

    /// Routes below `/nodes/{node}` that concern the node itself. nil for other paths.
    func handleNode(_ method: HTTPMethod, node: String, rest: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        settleNodeReboots()
        let isOnline = cluster.nodes.first { $0.name == node }?.isOnline ?? false
        let offline = failure(595, "Connection refused: node '\(node)' seems to be offline")
        let allowed = privileges(for: user)

        switch (method, rest) {
        case (.get, ["status"]):
            guard isOnline, let info = cluster.nodes.first(where: { $0.name == node }) else { return offline }
            return success(statusJSON(info))
        case (.post, ["status"]):
            guard isOnline else { return offline }
            guard allowed.contains("Sys.PowerMgmt") else { return failure(403, "Permission check failed (/nodes/\(node), Sys.PowerMgmt)") }
            switch parameters["command"] {
            case "reboot": powerOff(node, until: Date().addingTimeInterval(20))
            case "shutdown": powerOff(node, until: nil)
            default: return fieldFailure(["command": "value 'x' does not have a value in the enumeration 'reboot, shutdown'"])
            }
            return success(nil)
        case (.get, ["rrddata"]):
            guard let info = cluster.nodes.first(where: { $0.name == node }) else { return nil }
            return success(nodeHistory(info, timeframe: parameters["timeframe"] ?? "hour"))
        case (.get, ["services"]):
            guard isOnline else { return offline }
            return success(.array(Self.serviceList.map { service in
                let running = serviceStates[node + "/" + service.name] ?? (service.name != "corosync" || cluster.clusterName != nil)
                return [
                    "service": .string(service.name), "name": .string(service.name), "desc": .string(service.description),
                    "state": running ? "running" : "dead", "active-state": running ? "active" : "inactive", "unit-state": "enabled",
                ]
            }))
        case (.post, let path) where path.count == 3 && path[0] == "services":
            guard isOnline else { return offline }
            guard allowed.contains("Sys.Modify") else { return failure(403, "Permission check failed (/nodes/\(node), Sys.Modify)") }
            let name = path[1]
            guard Self.serviceList.contains(where: { $0.name == name }), let action = ["start", "stop", "restart", "reload"].first(where: { $0 == path[2] }) else {
                return failure(500, "unknown service command")
            }
            serviceStates[node + "/" + name] = action != "stop"
            return startTask(node: node, type: "srv" + action, objectID: name, user: user, duration: 1.5)
        case (.get, ["apt", "update"]):
            guard isOnline else { return offline }
            return success(.array(Self.availableUpdates.map { update in
                ["Package": .string(update.package), "Title": .string(update.title), "OldVersion": .string(update.old), "Version": .string(update.new), "Origin": "Proxmox", "Priority": "optional"]
            }))
        case (.post, ["apt", "update"]):
            guard isOnline else { return offline }
            return startTask(node: node, type: "aptupdate", objectID: "", user: user, duration: 3)
        case (.get, ["apt", "versions"]):
            let installed: [(String, String)] = [
                ("proxmox-ve", "9.0.0"), ("pve-manager", "9.0.10"), ("proxmox-kernel-6.14", "6.14.11-2"), ("qemu-server", "9.0.22"),
                ("pve-container", "6.0.13"), ("lxc-pve", "6.0.5-1"), ("pve-qemu-kvm", "10.0.2-4"), ("zfsutils-linux", "2.3.4-pve1"),
            ]
            return success(.array(installed.map { package, version in
                var entry: [String: JSONValue] = ["Package": .string(package), "Version": .string(version), "OldVersion": .string(version), "CurrentState": "Installed", "Origin": "Proxmox"]
                if package.hasPrefix("proxmox-kernel") { entry["RunningKernel"] = "6.14.11-2-pve" }
                return .object(entry)
            }))
        case (.get, ["journal"]):
            guard isOnline else { return offline }
            let count = min(Int(parameters["lastentries"] ?? "") ?? 50, 200)
            return success(.array(["s=demo;i=1;b=demo;m=0;t=0;x=0"] + journal(node, count: count).map { JSONValue.string($0) } + ["s=demo;i=2;b=demo;m=1;t=1;x=1"]))
        case (.get, ["tasks"]):
            let limit = Int(parameters["limit"] ?? "") ?? 50
            return success(.array(tasks.reversed().filter { $0.node == node }.prefix(limit).map(clusterTaskJSON)))
        default:
            return nil
        }
    }

    private func statusJSON(_ info: DemoCluster.Node) -> JSONValue {
        let gib = 1_073_741_824.0
        let elapsed = Date().timeIntervalSince(started)
        let used = cluster.guests.filter { $0.node == info.name && $0.isRunning }.reduce(2.5) { $0 + $1.memoryGiB * 0.8 }
        let load = Self.load(seed: info.name.unicodeScalars.reduce(0) { $0 + Int($1.value) }, elapsed: elapsed, base: 0.12, swing: 0.08)
        return [
            "cpu": .double(load), "wait": 0.002, "uptime": .int(uptime(of: info)),
            "loadavg": .array([load * Double(info.cores), load * Double(info.cores) * 0.9, load * Double(info.cores) * 0.8].map { .string(String(format: "%.2f", $0)) }),
            "memory": ["used": .int(Int(used * gib)), "total": .int(info.memoryGiB * Int(gib)), "free": .int(Int((Double(info.memoryGiB) - used) * gib))],
            "swap": ["used": 0, "total": .int(Int(8 * gib)), "free": .int(Int(8 * gib))],
            "rootfs": ["used": .int(Int(23 * gib)), "total": .int(Int(100 * gib)), "avail": .int(Int(77 * gib))],
            "cpuinfo": ["model": "AMD Ryzen 7 5800U with Radeon Graphics", "sockets": 1, "cores": .int(info.cores / 2), "cpus": .int(info.cores), "mhz": "1900.000"],
            "current-kernel": ["release": "6.14.11-2-pve", "sysname": "Linux", "machine": "x86_64"],
            "pveversion": .string("pve-manager/\(cluster.version)/demo"),
            "boot-info": ["mode": "efi", "secureboot": 1],
        ]
    }

    private func nodeHistory(_ info: DemoCluster.Node, timeframe: String) -> JSONValue {
        let step: TimeInterval = ["day": 1800, "week": 10_800, "month": 43_200, "year": 604_800][timeframe] ?? 60
        let end = (Date().timeIntervalSince1970 / step).rounded(.down) * step
        let total = Double(info.memoryGiB) * 1_073_741_824
        let seed = Double(info.name.unicodeScalars.reduce(0) { $0 + Int($1.value) })
        return .array((0..<70).map { index in
            let time = end - Double(69 - index) * step
            guard info.isOnline else { return ["time": .int(Int(time))] }
            let wave = sin(time / (step * 11) + seed) * 0.5 + 0.5
            return [
                "time": .int(Int(time)), "maxcpu": .int(info.cores), "cpu": .double(0.06 + 0.2 * wave),
                "memtotal": .double(total), "memused": .double(total * (0.35 + 0.15 * wave)),
                "netin": .double(20_000 + 300_000 * wave), "netout": .double(8_000 + 120_000 * (1 - wave)),
                "loadavg": .double(Double(info.cores) * (0.08 + 0.25 * wave)), "iowait": .double(0.002 + 0.01 * (1 - wave)),
            ]
        })
    }

    private func journal(_ node: String, count: Int) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd HH:mm:ss"
        let messages = [
            "pvedaemon[1064]: <root@pam> successful auth for user 'root@pam'",
            "pveproxy[2311]: worker 2412 finished",
            "pveproxy[2311]: starting 1 worker(s)",
            "pvestatd[1022]: status update time (0.512 seconds)",
            "systemd[1]: Starting apt-daily.service - Daily apt download activities...",
            "systemd[1]: apt-daily.service: Deactivated successfully.",
            "chronyd[812]: Selected source 162.159.200.123 (2.debian.pool.ntp.org)",
            "kernel: vmbr0: port 2(tap100i0) entered forwarding state",
            "pvescheduler[4410]: starting task UPID:\(node):00001139:demo:vzdump::root@pam:",
            "smartd[790]: Device: /dev/nvme0, SMART Health Status: OK",
        ]
        let now = Date()
        return (0..<count).map { index in
            let time = now.addingTimeInterval(-Double(count - index) * 47)
            return "\(formatter.string(from: time)) \(node) \(messages[index % messages.count])"
        }
    }

    private func uptime(of info: DemoCluster.Node) -> Int {
        if let booted = nodeBootTimes[info.name] { return max(0, Int(Date().timeIntervalSince(booted))) }
        return 1_814_400 + Int(Date().timeIntervalSince(started))
    }

    /// Stops the node and its guests; a reboot brings it back at `until`.
    private func powerOff(_ node: String, until: Date?) {
        guard let index = cluster.nodes.firstIndex(where: { $0.name == node }) else { return }
        cluster.nodes[index].isOnline = false
        for guest in cluster.guests.indices where cluster.guests[guest].node == node {
            cluster.guests[guest].isRunning = false
            cluster.guests[guest].isPaused = false
        }
        nodeReboots[node] = until
    }

    func settleNodeReboots() {
        let now = Date()
        for (node, until) in nodeReboots where until <= now {
            nodeReboots[node] = nil
            nodeBootTimes[node] = until
            if let index = cluster.nodes.firstIndex(where: { $0.name == node }) { cluster.nodes[index].isOnline = true }
        }
    }
}
