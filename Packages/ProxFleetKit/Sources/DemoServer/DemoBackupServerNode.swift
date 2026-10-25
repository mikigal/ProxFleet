import Foundation
import ProxmoxCore

/// The demo backup server's own system: services, updates, repositories, network, disks, certificate and options.
struct DemoBackupServerNodeState: Sendable {
    struct Disk: Sendable {
        var name: String
        var model: String
        var vendor: String?
        var serial: String
        /// `hdd`, `ssd`, `nvme` or `usb`.
        var type: String
        var sizeGiB: Double
        /// `unused`, `zfs`, `partitions`…
        var used: String
        var hasGPT: Bool
        var partitions: [Partition] = []
    }

    struct Partition: Sendable {
        var name: String
        var sizeGiB: Double
        var used: String
        var fileSystem: String?
        var uuid: String?
        var isMounted = false
    }

    struct Pool: Sendable {
        var name: String
        var raidLevel: String
        var devices: [String]
        var sizeGiB: Double
        var allocatedGiB: Double
    }

    struct Directory: Sendable {
        var name: String
        var device: String
        var fileSystem: String
        var isRemovable: Bool
    }

    struct Interface: Sendable, Equatable {
        var name: String
        var type: String
        var method = "manual"
        var cidr: String?
        var gateway: String?
        var autostart = true
        var bridgePorts: [String] = []
        var slaves: [String] = []
        var bondMode: String?
        var vlanAware = false
        var comments: String?
        var mtu: Int?
    }

    var services: [String: Bool] = [:]
    var dns = ["search": "home.arpa", "dns1": "10.0.10.1", "dns2": "1.1.1.1"]
    var timeZone = "Europe/Berlin"
    var options = ["email-from": "pbs@home.arpa", "task-log-max-days": "90",
                   "description": "**Home lab backups.** Nightly from the Proxmox VE cluster, copied to the USB disk on Sundays and to the cloud every morning.\n"]
    var repositories = ["enterprise": false, "no-subscription": true]
    var hasCustomCertificate = false
    var activeNetwork: [Interface] = [
        Interface(name: "lo", type: "loopback", method: "loopback"),
        Interface(name: "eno1", type: "eth"),
        Interface(name: "eno2", type: "eth", autostart: false),
        Interface(name: "vmbr0", type: "bridge", method: "static", cidr: "10.0.10.6/24", gateway: "10.0.10.1", bridgePorts: ["eno1"]),
    ]
    /// nil without pending changes.
    var pendingNetwork: [Interface]?
    var disks: [Disk] = [
        Disk(name: "nvme0n1", model: "Samsung SSD 980 500GB", vendor: nil, serial: "S64DNF0R812345", type: "nvme", sizeGiB: 465.8, used: "partitions", hasGPT: true,
             partitions: [Partition(name: "nvme0n1p1", sizeGiB: 0.001, used: "bios"), Partition(name: "nvme0n1p2", sizeGiB: 1, used: "efi", isMounted: true),
                          Partition(name: "nvme0n1p3", sizeGiB: 464.8, used: "lvm")]),
        Disk(name: "sda", model: "WDC WD40EFZX", vendor: "ATA", serial: "WD-WX12D81ABCDE", type: "hdd", sizeGiB: 3_726, used: "zfs", hasGPT: true),
        Disk(name: "sdb", model: "WDC WD40EFZX", vendor: "ATA", serial: "WD-WX12D81FGHIJ", type: "hdd", sizeGiB: 3_726, used: "zfs", hasGPT: true),
        Disk(name: "sdc", model: "Samsung T7", vendor: "Samsung", serial: "S5SXNG0R345678", type: "usb", sizeGiB: 1_863, used: "partitions", hasGPT: true,
             partitions: [Partition(name: "sdc1", sizeGiB: 1_863, used: "filesystem", fileSystem: "ext4", uuid: "c3d7e1f0-5a2b-4c9e-8f61-2b7d40a9e113")]),
        Disk(name: "sdd", model: "WDC WD20EFRX", vendor: "ATA", serial: "WD-WCC4M1KLMNOP", type: "hdd", sizeGiB: 1_863, used: "unused", hasGPT: false),
    ]
    var pools = [Pool(name: "main", raidLevel: "mirror", devices: ["sda", "sdb"], sizeGiB: 3_626, allocatedGiB: 1_184)]
    var directories: [Directory] = []
}

extension DemoBackupServerState {
    private static let serviceList: [(name: String, description: String, unitState: String)] = [
        ("proxmox-backup", "Proxmox Backup API Server", "enabled"), ("proxmox-backup-proxy", "Proxmox Backup API Proxy Server", "enabled"),
        ("sshd", "OpenBSD Secure Shell server", "enabled"), ("systemd-journald", "Journal Service", "static"),
        ("cron", "Regular background program processing daemon", "enabled"), ("postfix", "Postfix Mail Transport Agent (main/default instance)", "enabled"),
        ("chrony", "chrony, an NTP client/server", "enabled"),
    ]

    private static let availableUpdates: [(package: String, title: String, old: String, new: String)] = [
        ("proxmox-backup-server", "Proxmox Backup Server daemon with tools and GUI", "4.2.1-1", "4.2.2-1"),
        ("proxmox-backup-client", "Proxmox Backup Client tools", "4.2.1-1", "4.2.2-1"),
        ("proxmox-widget-toolkit", "Core Widgets and Mixins for the Proxmox GUIs", "5.1.2", "5.1.3"),
    ]

    private static let standardRepositories: [(handle: String, name: String, description: String, uri: String, component: String)] = [
        ("enterprise", "Enterprise", "This is the default, stable, and recommended repository, available for all Proxmox subscription users.",
         "https://enterprise.proxmox.com/debian/pbs", "pbs-enterprise"),
        ("no-subscription", "No-Subscription", "This is the recommended repository for testing and non-production use. Its packages are not as heavily tested and validated as the production ready enterprise repository. You don't need a subscription key to access this repository.",
         "http://download.proxmox.com/debian/pbs", "pbs-no-subscription"),
        ("test", "Test", "This repository contains the latest packages and is primarily used for test labs and by developers to test new features.",
         "http://download.proxmox.com/debian/pbs", "pbs-test"),
    ]

    private static let interfaceKeys: Set<String> = [
        "iface", "type", "autostart", "method", "method6", "cidr", "cidr6", "gateway", "gateway6", "comments", "comments6", "mtu",
        "bridge_ports", "bridge_vlan_aware", "slaves", "bond_mode", "bond-primary", "bond_xmit_hash_policy", "vlan-id", "vlan-raw-device", "delete", "digest",
    ]

    /// Routes below `/nodes/localhost` for the server's own system. nil for other paths.
    func handleServerAdministration(_ method: HTTPMethod, rest: [String], parameters: [String: String]) -> HTTPResponse? {
        switch (method, rest) {
        case (.post, ["status"]):
            guard ["reboot", "shutdown"].contains(parameters["command"] ?? "") else {
                return fieldFailure(["command": "value does not match the regex pattern"])
            }
            return success(nil)
        case (.get, ["services"]):
            return success(.array(Self.serviceList.map { service in
                let running = node.services[service.name] ?? true
                return ["service": .string(service.name), "name": .string(service.name), "desc": .string(service.description),
                        "state": running ? "running" : "dead", "unit-state": .string(service.unitState)]
            }))
        case (.post, let path) where path.count == 3 && path[0] == "services":
            guard Self.serviceList.contains(where: { $0.name == path[1] }), ["start", "stop", "restart", "reload"].contains(path[2]) else {
                return failure(400, "unknown service command")
            }
            node.services[path[1]] = path[2] != "stop"
            return startTask("srv\(path[2])", path[1], duration: 1)
        case (.get, ["apt", "update"]):
            return success(.array(Self.availableUpdates.map { update in
                ["Package": .string(update.package), "Title": .string(update.title), "OldVersion": .string(update.old), "Version": .string(update.new),
                 "Origin": "Proxmox", "Priority": "optional"]
            }))
        case (.post, ["apt", "update"]):
            return startTask("aptupdate", "", duration: 3)
        case (.get, ["apt", "versions"]):
            let installed: [(String, String, String?)] = [
                ("proxmox-backup", "4.2.0", "running kernel: 6.17.2-1-pve"), ("proxmox-backup-server", "4.2.1-1", "running version: 4.2.1"),
                ("proxmox-backup-client", "4.2.1-1", nil), ("proxmox-kernel-6.17", "6.17.2-1", nil), ("zfsutils-linux", "2.3.4-pve1", nil),
            ]
            return success(.array(installed.map { package, version, extra in
                var entry: [String: JSONValue] = ["Package": .string(package), "Version": .string(version), "OldVersion": .string(version), "Origin": "Proxmox"]
                if let extra { entry["ExtraInfo"] = .string(extra) }
                return .object(entry)
            }))
        case (.get, ["apt", "changelog"]):
            let package = parameters["name"] ?? ""
            let version = parameters["version"] ?? Self.availableUpdates.first { $0.package == package }?.new ?? "1.0"
            return success(.string("\(package) (\(version)) trixie; urgency=medium\n\n  * Fix the problems the previous version had in demo mode.\n\n -- Proxmox Support Team <support@proxmox.com>  Mon, 13 Oct 2026 10:00:00 +0200\n"))
        case (.get, ["apt", "repositories"]):
            return success(repositoriesJSON())
        case (.post, ["apt", "repositories"]):
            let index = Int(parameters["index"] ?? "") ?? -1
            let handles = Self.standardRepositories.map(\.handle).filter { node.repositories[$0] != nil }
            guard parameters["path"] == "/etc/apt/sources.list.d/proxmox.sources", handles.indices.contains(index) else {
                return failure(400, "repository not found")
            }
            node.repositories[handles[index]] = parameters["enabled"] == "1"
            return success(nil)
        case (.put, ["apt", "repositories"]):
            guard let handle = parameters["handle"], Self.standardRepositories.contains(where: { $0.handle == handle }) else {
                return fieldFailure(["handle": "value is not defined in the enumeration"])
            }
            guard node.repositories[handle] == nil else { return failure(400, "repository already configured") }
            node.repositories[handle] = true
            return success(nil)
        case (.get, ["journal"]):
            let count = min(Int(parameters["lastentries"] ?? "") ?? 50, 200)
            return success(.array(["s=demo;i=1;b=demo;m=0;t=0;x=0"] + journal(count: count).map { JSONValue.string($0) } + ["s=demo;i=2;b=demo;m=1;t=1;x=1"]))
        case (.get, ["report"]):
            return success(.string("""
            ## FILES

            ### General System Info

            `$ cat '/etc/hostname'`
            ```
            \(server.name)
            ```

            ### Datastores

            `$ proxmox-backup-manager datastore list`
            ```
            \(server.datastores.map { "\($0.name)  \($0.path)  \($0.comment)" }.joined(separator: "\n"))
            ```
            """))
        case (.get, ["dns"]):
            var data = node.dns.mapValues { JSONValue.string($0) }
            data["digest"] = .string(String(format: "%064x", node.dns.values.joined().hashValue & 0xFFFF))
            return success(.object(data))
        case (.put, ["dns"]):
            for key in (parameters["delete"] ?? "").components(separatedBy: DemoState.listSeparator) where !key.isEmpty {
                node.dns[key] = nil
            }
            for key in ["search", "dns1", "dns2", "dns3"] {
                if let value = parameters[key] { node.dns[key] = value }
            }
            return success(nil)
        case (.get, ["time"]):
            let now = Int(Date().timeIntervalSince1970)
            let offset = TimeZone(identifier: node.timeZone)?.secondsFromGMT() ?? 0
            return success(["time": .int(now), "localtime": .int(now + offset), "timezone": .string(node.timeZone)])
        case (.put, ["time"]):
            guard let zone = parameters["timezone"], TimeZone(identifier: zone) != nil else {
                return fieldFailure(["timezone": "Invalid time zone"])
            }
            node.timeZone = zone
            return success(nil)
        case (.get, ["config"]):
            return digested(.object(node.options.mapValues { JSONValue.string($0) }))
        case (.put, ["config"]):
            if let digest = parameters["digest"], digest != configDigest {
                return failure(400, "detected modified configuration - file changed by other user? Try again.")
            }
            let allowed: Set<String> = ["http-proxy", "email-from", "default-lang", "description", "task-log-max-days", "consent-text",
                                        "ciphers-tls-1.2", "ciphers-tls-1.3", "acme", "delete", "digest"]
            if let unknown = parameters.keys.first(where: { !allowed.contains($0) && !$0.hasPrefix("acmedomain") }) {
                return fieldFailure([unknown: "schema does not allow additional properties"])
            }
            if let proxy = parameters["http-proxy"], proxy.contains(" ") {
                return fieldFailure(["http-proxy": "value does not match the regex pattern"])
            }
            for key in (parameters["delete"] ?? "").components(separatedBy: DemoState.listSeparator) where !key.isEmpty {
                node.options[key] = nil
            }
            for (key, value) in parameters where !["delete", "digest"].contains(key) { node.options[key] = value }
            configRevision += 1
            return success(nil)
        case (.get, ["certificates", "info"]):
            return success(.array([certificateJSON()]))
        case (.post, ["certificates", "custom"]):
            guard parameters["certificates"]?.contains("BEGIN CERTIFICATE") == true else {
                return fieldFailure(["certificates": "unable to parse certificate"])
            }
            node.hasCustomCertificate = true
            return success(.array([certificateJSON()]))
        case (.delete, ["certificates", "custom"]):
            node.hasCustomCertificate = false
            return success(nil)
        default:
            return handleServerNetwork(method, rest: rest, parameters: parameters) ?? handleServerDisks(method, rest: rest, parameters: parameters)
        }
    }

    private func journal(count: Int) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let messages = [
            "proxmox-backup-proxy[912]: starting new backup on datastore 'main' from ::ffff:10.0.10.2: \"ns/homelab/vm/100/\(Int(started.timeIntervalSince1970))\"",
            "proxmox-backup-proxy[912]: Upload statistics for 'drive-scsi0.img.fidx'",
            "proxmox-backup-proxy[912]: successfully finished backup",
            "proxmox-backup-proxy[912]: TASK OK",
            "postfix/pickup[4211]: 6A1F02C0E1: uid=0 from=<root>",
            "chronyd[701]: Selected source 10.0.10.1 (ntp.home.arpa)",
        ]
        return (0..<count).map { index in
            let date = Date().addingTimeInterval(Double(index - count) * 37)
            return "\(formatter.string(from: date)) \(server.name) \(messages[index % messages.count])"
        }
    }

    private func repositoriesJSON() -> JSONValue {
        var repositories: [JSONValue] = []
        var infos: [JSONValue] = []
        for standard in Self.standardRepositories {
            guard let enabled = node.repositories[standard.handle] else { continue }
            infos.append(["path": "/etc/apt/sources.list.d/proxmox.sources", "index": .int(repositories.count), "kind": "origin", "message": "Proxmox"])
            repositories.append([
                "Types": ["deb"], "URIs": [.string(standard.uri)], "Suites": ["trixie"], "Components": [.string(standard.component)],
                "Enabled": .int(enabled ? 1 : 0), "FileType": "sources",
            ])
        }
        let debian: JSONValue = [
            "Types": ["deb"], "URIs": ["http://deb.debian.org/debian/"], "Suites": ["trixie", "trixie-updates"],
            "Components": ["main", "contrib", "non-free-firmware"], "Enabled": 1, "FileType": "sources",
        ]
        let standard: [JSONValue] = Self.standardRepositories.map { repository in
            var object: [String: JSONValue] = ["handle": .string(repository.handle), "name": .string(repository.name), "description": .string(repository.description)]
            if let enabled = node.repositories[repository.handle] { object["status"] = .int(enabled ? 1 : 0) }
            return .object(object)
        }
        let digest = String(format: "%064x", node.repositories.map { "\($0.key)\($0.value)" }.sorted().joined().hashValue & 0xFFFFFF)
        return [
            "files": [
                ["path": "/etc/apt/sources.list.d/debian.sources", "file-type": "sources", "repositories": [debian], "digest": [0, 1]],
                ["path": "/etc/apt/sources.list.d/proxmox.sources", "file-type": "sources", "repositories": .array(repositories), "digest": [1, 2]],
            ],
            "infos": .array(infos + [["path": "/etc/apt/sources.list.d/debian.sources", "index": 0, "kind": "origin", "message": "Debian"]]),
            "errors": [], "standard-repos": .array(standard), "digest": .string(digest),
        ]
    }

    private func certificateJSON() -> JSONValue {
        let issued = node.hasCustomCertificate ? started : started.addingTimeInterval(-86_400 * 400)
        let subject = node.hasCustomCertificate ? "CN = pbs.example.net" : "O = Proxmox Backup Server, OU = 2E7A51C0-DEMO, CN = \(server.name).home.arpa"
        return [
            "filename": "proxy.pem", "subject": .string(subject),
            "issuer": .string(node.hasCustomCertificate ? "C = US, O = Let's Encrypt, CN = R11" : subject),
            "notbefore": .int(Int(issued.timeIntervalSince1970)),
            "notafter": .int(Int(issued.timeIntervalSince1970) + 86_400 * (node.hasCustomCertificate ? 90 : 365_000)),
            "fingerprint": node.hasCustomCertificate
                ? "9e:42:b1:0c:d8:77:3a:e5:16:f0:6b:c9:28:54:a3:dd:01:7f:be:62:90:4c:e1:35:a8:5d:0b:f7:c3:19:66:2e"
                : "5b:0e:c2:71:9a:33:d8:46:e1:7f:20:bb:94:5c:08:a6:3d:e9:12:47:fc:81:6a:d5:2b:90:cf:34:71:e8:0d:a2",
            "public-key-type": "rsaEncryption", "public-key-bits": 4096,
            "san": .array(["localhost", .string(server.name), .string("\(server.name).home.arpa"), .string(server.ip)]),
        ]
    }

    // MARK: - Network

    private func handleServerNetwork(_ method: HTTPMethod, rest: [String], parameters: [String: String]) -> HTTPResponse? {
        guard rest.first == "network" else { return nil }
        switch (method, rest) {
        case (.get, ["network"]):
            let interfaces = node.pendingNetwork ?? node.activeNetwork
            var body: [String: JSONValue] = [
                "data": .array(interfaces.map { interfaceJSON($0, active: node.activeNetwork.contains($0)) }), "success": true,
                "digest": .string(String(format: "%064x", interfaces.map(\.name).joined().hashValue & 0xFFFFFF)),
            ]
            if let pending = node.pendingNetwork { body["changes"] = .string(Self.networkDiff(node.activeNetwork, pending)) }
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: JSONValue.object(body).encoded())
        case (.post, ["network"]):
            if let unknown = parameters.keys.first(where: { !Self.interfaceKeys.contains($0) }) {
                return fieldFailure([unknown: "schema does not allow additional properties"])
            }
            guard let name = parameters["iface"], !name.isEmpty else { return fieldFailure(["iface": "parameter is missing and it is not optional."]) }
            var interfaces = node.pendingNetwork ?? node.activeNetwork
            guard !interfaces.contains(where: { $0.name == name }) else { return failure(400, "interface '\(name)' already exists") }
            var interface = DemoBackupServerNodeState.Interface(name: name, type: parameters["type"] ?? "unknown", autostart: false)
            if let problem = apply(parameters, to: &interface, others: interfaces) { return problem }
            interfaces.append(interface)
            node.pendingNetwork = interfaces
            return success(nil)
        case (.put, let path) where path.count == 2:
            if let unknown = parameters.keys.first(where: { !Self.interfaceKeys.contains($0) }) {
                return fieldFailure([unknown: "schema does not allow additional properties"])
            }
            var interfaces = node.pendingNetwork ?? node.activeNetwork
            guard let index = interfaces.firstIndex(where: { $0.name == path[1] }) else { return failure(400, "interface '\(path[1])' does not exist") }
            var interface = interfaces[index]
            for key in (parameters["delete"] ?? "").components(separatedBy: DemoState.listSeparator) where !key.isEmpty {
                switch key {
                case "cidr": interface.cidr = nil
                case "gateway": interface.gateway = nil
                case "comments": interface.comments = nil
                case "mtu": interface.mtu = nil
                case "bridge_ports": interface.bridgePorts = []
                case "slaves": interface.slaves = []
                case "autostart": interface.autostart = false
                case "bridge_vlan_aware": interface.vlanAware = false
                default: break
                }
            }
            if let problem = apply(parameters, to: &interface, others: interfaces.filter { $0.name != path[1] }) { return problem }
            interfaces[index] = interface
            node.pendingNetwork = interfaces
            return success(nil)
        case (.delete, let path) where path.count == 2:
            var interfaces = node.pendingNetwork ?? node.activeNetwork
            guard interfaces.contains(where: { $0.name == path[1] }) else { return failure(400, "interface '\(path[1])' does not exist") }
            interfaces.removeAll { $0.name == path[1] }
            node.pendingNetwork = interfaces
            return success(nil)
        case (.put, ["network"]):
            if let pending = node.pendingNetwork { node.activeNetwork = pending }
            node.pendingNetwork = nil
            // Like the real server, a task, although the API schema says it returns nothing.
            return startTask("srvreload", "networking", duration: 1)
        case (.delete, ["network"]):
            node.pendingNetwork = nil
            return success(nil)
        default:
            return nil
        }
    }

    /// Applies interface settings as the real server takes them: member lists comma-separated.
    private func apply(_ parameters: [String: String], to interface: inout DemoBackupServerNodeState.Interface,
                       others: [DemoBackupServerNodeState.Interface]) -> HTTPResponse? {
        func list(_ key: String) -> [String]? {
            parameters[key].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        }
        if let ports = list("bridge_ports") {
            if let missing = ports.first(where: { port in !others.contains { $0.name == port } }) {
                return fieldFailure(["bridge_ports": "unknown interface '\(missing)'"])
            }
            interface.bridgePorts = ports
        }
        if let slaves = list("slaves") { interface.slaves = slaves }
        if let cidr = parameters["cidr"] {
            guard cidr.contains("/") else { return fieldFailure(["cidr": "value does not match the regex pattern"]) }
            interface.cidr = cidr
            interface.method = "static"
        }
        if let gateway = parameters["gateway"] { interface.gateway = gateway }
        if let comments = parameters["comments"] { interface.comments = comments }
        if let mtu = parameters["mtu"].flatMap(Int.init) { interface.mtu = mtu }
        if let mode = parameters["bond_mode"] { interface.bondMode = mode }
        if let autostart = parameters["autostart"] { interface.autostart = autostart == "1" }
        if let aware = parameters["bridge_vlan_aware"] { interface.vlanAware = aware == "1" }
        return nil
    }

    private func interfaceJSON(_ interface: DemoBackupServerNodeState.Interface, active: Bool) -> JSONValue {
        var data: [String: JSONValue] = [
            "name": .string(interface.name), "iface": .string(interface.name), "type": .string(interface.type), "method": .string(interface.method),
            "autostart": .bool(interface.autostart), "active": .bool(active),
        ]
        if let cidr = interface.cidr { data["cidr"] = .string(cidr) }
        if let gateway = interface.gateway { data["gateway"] = .string(gateway) }
        if let comments = interface.comments { data["comments"] = .string(comments) }
        if let mtu = interface.mtu { data["mtu"] = .int(mtu) }
        if interface.type == "bridge" {
            data["bridge_ports"] = .array(interface.bridgePorts.map { .string($0) })
            data["bridge_vlan_aware"] = .bool(interface.vlanAware)
        }
        if interface.type == "bond" {
            data["slaves"] = .array(interface.slaves.map { .string($0) })
            data["bond_mode"] = .string(interface.bondMode ?? "balance-rr")
        }
        return .object(data)
    }

    private static func networkDiff(_ old: [DemoBackupServerNodeState.Interface], _ new: [DemoBackupServerNodeState.Interface]) -> String {
        var lines = ["--- /etc/network/interfaces", "+++ /etc/network/interfaces.new"]
        for interface in new where !old.contains(interface) {
            lines.append("+auto \(interface.name)")
            lines.append("+iface \(interface.name) inet \(interface.method)")
            if let cidr = interface.cidr { lines.append("+\taddress \(cidr)") }
            if interface.type == "bridge" { lines.append("+\tbridge-ports \(interface.bridgePorts.isEmpty ? "none" : interface.bridgePorts.joined(separator: " "))") }
        }
        for interface in old where !new.contains(where: { $0.name == interface.name }) {
            lines.append("-iface \(interface.name) inet \(interface.method)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Disks

    private func handleServerDisks(_ method: HTTPMethod, rest: [String], parameters: [String: String]) -> HTTPResponse? {
        guard rest.first == "disks" else { return nil }
        let gib = 1_073_741_824.0
        switch (method, rest) {
        case (.get, ["disks", "list"]):
            let withPartitions = parameters["include-partitions"] == "1"
            return success(.array(node.disks.map { disk in
                var data: [String: JSONValue] = [
                    "name": .string(disk.name), "devpath": .string("/dev/\(disk.name)"), "disk-type": .string(disk.type), "gpt": .bool(disk.hasGPT),
                    "model": .string(disk.model), "serial": .string(disk.serial), "size": .double(disk.sizeGiB * gib), "used": .string(disk.used),
                    "status": .string(parameters["skipsmart"] == "1" ? "unknown" : disk.type == "usb" ? "unknown" : "passed"), "rpm": nil, "wwn": nil,
                    "wearout": disk.type == "nvme" ? 97 : nil,
                ]
                if let vendor = disk.vendor { data["vendor"] = .string(vendor) }
                if withPartitions {
                    data["partitions"] = .array(disk.partitions.map { partition in
                        [
                            "name": .string(partition.name), "devpath": .string("/dev/\(partition.name)"), "size": .double(partition.sizeGiB * gib),
                            "used": .string(partition.used), "filesystem": partition.fileSystem.map { .string($0) } ?? nil,
                            "uuid": partition.uuid.map { .string($0) } ?? nil, "mounted": .bool(partition.isMounted), "gpt": .bool(disk.hasGPT),
                        ]
                    })
                }
                return .object(data)
            }))
        case (.get, ["disks", "smart"]):
            guard let disk = node.disks.first(where: { $0.name == parameters["disk"] }) else {
                return fieldFailure(["disk": "value does not match the regex pattern"])
            }
            guard disk.type == "hdd" else { return success(["status": "unknown", "attributes": [], "wearout": nil]) }
            let attributes: [(String, String, String, String, String, String)] = [
                ("1", "Raw_Read_Error_Rate", "200", "200", "051", "0"), ("5", "Reallocated_Sector_Ct", "200", "200", "140", "0"),
                ("9", "Power_On_Hours", "057", "057", "000", "31544"), ("194", "Temperature_Celsius", "117", "105", "000", "33"),
                ("197", "Current_Pending_Sector", "200", "200", "000", "0"),
            ]
            return success([
                "status": "passed", "wearout": nil,
                "attributes": .array(attributes.map { id, name, value, worst, threshold, raw in
                    ["id": .string(id), "name": .string(name), "value": .string(value), "worst": .string(worst), "threshold": .string(threshold),
                     "raw": .string(raw), "fail": "-", "flags": "POSR-K", "normalized": .double(Double(value) ?? 0)]
                }),
            ])
        case (.post, ["disks", "initgpt"]), (.put, ["disks", "wipedisk"]):
            guard let index = node.disks.firstIndex(where: { $0.name == parameters["disk"] }) else {
                return fieldFailure(["disk": "value does not match the regex pattern"])
            }
            let disk = node.disks[index]
            // A new partition table needs an unused disk; wiping refuses disks in a pool, under a mounted directory or the system disk.
            let inUse = rest[1] == "initgpt"
                ? disk.used != "unused"
                : disk.used == "zfs" || disk.type == "nvme" || node.directories.contains { $0.device.hasPrefix("/dev/\(disk.name)") }
            guard !inUse else { return failure(400, "disk '\(disk.name)' is in use") }
            node.disks[index].partitions = []
            node.disks[index].used = "unused"
            node.disks[index].hasGPT = rest[1] == "initgpt"
            return startTask(rest[1] == "initgpt" ? "diskinit" : "wipedisk", node.disks[index].name, duration: 2)
        case (.get, ["disks", "zfs"]):
            return success(.array(node.pools.map { pool in
                ["name": .string(pool.name), "size": .double(pool.sizeGiB * gib), "alloc": .double(pool.allocatedGiB * gib),
                 "free": .double((pool.sizeGiB - pool.allocatedGiB) * gib), "frag": 3, "dedup": 1.0, "health": "ONLINE"]
            }))
        case (.get, let path) where path.count == 3 && path[1] == "zfs":
            guard let pool = node.pools.first(where: { $0.name == path[2] }) else { return failure(400, "pool '\(path[2])' does not exist") }
            let leaves: [JSONValue] = pool.devices.map { ["name": .string("ata-\($0)"), "state": "ONLINE", "read": 0, "write": 0, "cksum": 0, "msg": "", "leaf": 1] }
            let vdevs: [JSONValue] = pool.raidLevel == "single" ? leaves
                : [["name": .string("\(pool.raidLevel == "raidz" ? "raidz1" : pool.raidLevel)-0"), "state": "ONLINE", "read": 0, "write": 0, "cksum": 0, "msg": "",
                    "children": .array(leaves)]]
            return success([
                "name": .string(pool.name), "state": "ONLINE", "errors": "No known data errors",
                "scan": "scrub repaired 0B in 04:02:11 with 0 errors on Sun Oct 11 04:26:12 2026",
                "children": [["name": .string(pool.name), "state": "ONLINE", "read": 0, "write": 0, "cksum": 0, "msg": "", "children": .array(vdevs)]],
            ])
        case (.get, ["disks", "directory"]):
            return success(.array(node.directories.map { directory in
                // The real server lists the name with a leading slash.
                ["name": .string("/\(directory.name)"), "path": .string("/mnt/datastore/\(directory.name)"), "device": .string(directory.device),
                 "filesystem": .string(directory.fileSystem), "unitfile": .string("/etc/systemd/system/mnt-datastore-\(directory.name).mount"),
                 "removable": .bool(directory.isRemovable)]
            }))
        case (.post, ["disks", "directory"]), (.post, ["disks", "zfs"]):
            return createDiskStorage(kind: rest[1], parameters: parameters)
        case (.delete, let path) where path.count == 3 && path[1] == "directory":
            guard let index = node.directories.firstIndex(where: { $0.name == path[2] }) else {
                return failure(400, "directory '\(path[2])' does not exist")
            }
            if datastoreIndex(path[2]) != nil, !node.directories[index].isRemovable {
                return failure(400, "cannot remove mount point for datastore '\(path[2])', remove the datastore first")
            }
            node.directories.remove(at: index)
            return success(nil)
        default:
            return nil
        }
    }

    private func createDiskStorage(kind: String, parameters: [String: String]) -> HTTPResponse {
        let name = parameters["name"] ?? ""
        guard name.count >= 3, name.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._\-]*/) != nil else {
            return fieldFailure(["name": "value does not match the regex pattern"])
        }
        let names = (kind == "zfs" ? parameters["devices"] : parameters["disk"])?.split(separator: ",").map(String.init) ?? []
        guard !names.isEmpty, names.allSatisfy({ name in node.disks.contains { $0.name == name } }) else {
            return fieldFailure([kind == "zfs" ? "devices" : "disk": "value does not match the regex pattern"])
        }
        if let used = names.first(where: { name in node.disks.first { $0.name == name }?.used != "unused" }) {
            return failure(400, "disk '\(used)' is already in use")
        }
        let addsDatastore = parameters["add-datastore"] == "1"
        if addsDatastore, datastoreIndex(name) != nil { return failure(400, "datastore '\(name)' already exists.") }
        if kind == "zfs" {
            let level = parameters["raidlevel"] ?? "single"
            let minimum = ["mirror": 2, "raid10": 4, "raidz": 3, "raidz2": 4, "raidz3": 5][level] ?? 1
            guard names.count >= minimum else { return failure(400, "\(level) needs at least \(minimum) disks") }
            let sizes = names.compactMap { name in node.disks.first { $0.name == name }?.sizeGiB }
            let usable = level == "single" ? sizes.reduce(0, +) : (sizes.min() ?? 0) * Double(max(1, names.count - (minimum - 1)))
            node.pools.append(DemoBackupServerNodeState.Pool(name: name, raidLevel: level, devices: names, sizeGiB: usable * 0.97, allocatedGiB: 0.01))
            for disk in names { node.disks[node.disks.firstIndex { $0.name == disk }!].used = "zfs" }
        } else {
            let index = node.disks.firstIndex { $0.name == names[0] }!
            let fileSystem = parameters["filesystem"] ?? "ext4"
            let uuid = UUID().uuidString.lowercased()
            node.disks[index].used = "partitions"
            node.disks[index].hasGPT = true
            node.disks[index].partitions = [DemoBackupServerNodeState.Partition(name: "\(names[0])1", sizeGiB: node.disks[index].sizeGiB, used: "filesystem",
                                                                                fileSystem: fileSystem, uuid: uuid, isMounted: true)]
            node.directories.append(DemoBackupServerNodeState.Directory(name: name, device: "/dev/\(names[0])1", fileSystem: fileSystem,
                                                                        isRemovable: parameters["removable-datastore"] == "1"))
        }
        if addsDatastore {
            let removable = parameters["removable-datastore"] == "1"
            let sizeGiB = kind == "zfs" ? node.pools.last!.sizeGiB : node.disks.first { $0.name == names[0] }!.sizeGiB
            let backingDevice = removable ? node.disks.first { $0.name == names[0] }?.partitions.first?.uuid : nil
            server.datastores.append(DemoBackupServer.Datastore(
                name: name, path: removable ? name : "/mnt/datastore/\(name)", comment: "", totalGiB: sizeGiB, usedGiB: 0.01,
                backingDevice: backingDevice, gcSchedule: "daily", namespaces: [""], groups: []
            ))
            var settings = ["name": name, "path": removable ? name : "/mnt/datastore/\(name)", "gc-schedule": "daily", "notification-mode": "notification-system"]
            if let backingDevice { settings["backing-device"] = backingDevice }
            datastoreSettings[name] = settings
            configRevision += 1
        }
        return startTask(kind == "zfs" ? "zfscreate" : "dircreate", name, duration: 3)
    }
}
