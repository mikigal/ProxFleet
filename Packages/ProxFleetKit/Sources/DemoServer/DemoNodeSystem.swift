import Foundation
import ProxmoxCore

/// One interface of `/etc/network/interfaces` in demo mode: `iface`, `type` and the settings as the API names them.
struct DemoInterface: Sendable, Equatable {
    var values: [String: String]

    var name: String { values["iface"] ?? "" }
    var type: String { values["type"] ?? "" }
    var members: [String] {
        ["bridge_ports", "slaves"].flatMap { (values[$0] ?? "").split(separator: " ").map(String.init) }
    }

    /// The stanza as ifupdown2 writes it, for the diff of pending changes.
    var stanza: [String] {
        var lines: [String] = []
        if values["autostart"] == "1" { lines.append("auto \(name)") }
        lines.append("iface \(name) inet \(values["cidr"] == nil ? "manual" : "static")")
        let keys: [(String, String)] = [
            ("cidr", "address"), ("gateway", "gateway"), ("bridge_ports", "bridge-ports"), ("bridge_vlan_aware", "bridge-vlan-aware"),
            ("bridge_vids", "bridge-vids"), ("slaves", "bond-slaves"), ("bond_mode", "bond-mode"), ("bond-primary", "bond-primary"),
            ("bond_xmit_hash_policy", "bond-xmit-hash-policy"), ("vlan-raw-device", "vlan-raw-device"), ("vlan-id", "vlan-id"), ("mtu", "mtu"),
        ]
        for (key, option) in keys {
            guard let value = values[key] else { continue }
            lines.append("\t\(option) \(key == "bridge_vlan_aware" ? "yes" : value)")
        }
        if type == "bridge" {
            if values["bridge_ports"] == nil { lines.append("\tbridge-ports none") }
            lines += ["\tbridge-stp off", "\tbridge-fd 0"]
        }
        if let comments = values["comments"] { lines.append("#\(comments)") }
        if let cidr6 = values["cidr6"] {
            lines += ["", "iface \(name) inet6 static", "\taddress \(cidr6)"] + (values["gateway6"].map { ["\tgateway \($0)"] } ?? [])
        }
        return lines + [""]
    }
}

/// DNS, hosts, time zone and network settings of nodes in demo mode.
extension DemoState {
    private static let configKeys: Set<String> = [
        "autostart", "cidr", "gateway", "cidr6", "gateway6", "mtu", "comments", "bridge_ports", "bridge_vlan_aware", "bridge_vids",
        "slaves", "bond_mode", "bond-primary", "bond_xmit_hash_policy", "vlan-raw-device", "vlan-id",
    ]

    /// Routes for `dns`, `hosts`, `time` and `network` below `/nodes/{node}`. nil for other paths.
    func handleNodeSystem(_ method: HTTPMethod, node: String, rest: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        guard let info = cluster.nodes.first(where: { $0.name == node }), ["dns", "hosts", "time", "network"].contains(rest.first ?? "") else { return nil }
        guard info.isOnline else { return failure(595, "Connection refused: node '\(node)' seems to be offline") }
        if method != .get, !privileges(for: user).contains("Sys.Modify") {
            return failure(403, "Permission check failed (/nodes/\(node), Sys.Modify)")
        }

        switch (method, rest) {
        case (.get, ["dns"]):
            return success(.object(dnsSettings(node).mapValues { .string($0) }))
        case (.put, ["dns"]):
            guard let search = parameters["search"] else { return fieldFailure(["search": "property is missing and it is not optional"]) }
            var settings = ["search": search]
            for key in ["dns1", "dns2", "dns3"] {
                guard let server = parameters[key], !server.isEmpty else { continue }
                guard Self.isIPAddress(server) else { return fieldFailure([key: "value does not look like a valid IP address"]) }
                settings[key] = server
            }
            nodeDNS[node] = settings
            return success(nil)
        case (.get, ["hosts"]):
            let text = hostsFile(node, ip: info.ip)
            return success(["data": .string(text), "digest": .string(Self.digest(text))])
        case (.post, ["hosts"]):
            if let digest = parameters["digest"], digest != Self.digest(hostsFile(node, ip: info.ip)) {
                return failure(500, "detected modified configuration - file changed by other user? Try again.")
            }
            nodeHosts[node] = parameters["data"] ?? ""
            return success(nil)
        case (.get, ["time"]):
            let zone = nodeTimeZones[node] ?? "Europe/Berlin"
            let now = Int(Date().timeIntervalSince1970)
            let offset = TimeZone(identifier: zone)?.secondsFromGMT() ?? 0
            return success(["timezone": .string(zone), "time": .int(now), "localtime": .int(now + offset)])
        case (.put, ["time"]):
            guard let zone = parameters["timezone"], TimeZone(identifier: zone) != nil else { return fieldFailure(["timezone": "No such timezone"]) }
            nodeTimeZones[node] = zone
            return success(nil)
        case (.get, ["network"]):
            return networkList(node: node, type: parameters["type"])
        case (.get, let path) where path.count == 2:
            guard let interface = pendingNetwork(node).first(where: { $0.name == path[1] }) else { return failure(500, "interface does not exist") }
            return success(interfaceJSON(interface, node: node))
        case (.post, ["network"]):
            return createInterface(node: node, parameters: parameters)
        case (.put, let path) where path.count == 2:
            return updateInterface(node: node, name: path[1], parameters: parameters)
        case (.delete, let path) where path.count == 2:
            var interfaces = pendingNetwork(node)
            guard let index = interfaces.firstIndex(where: { $0.name == path[1] }) else { return failure(500, "interface does not exist") }
            interfaces.remove(at: index)
            pendingNetworks[node] = interfaces
            return success(nil)
        case (.put, ["network"]):
            if let pending = pendingNetworks.removeValue(forKey: node) { activeNetworks[node] = pending }
            return startTask(node: node, type: "srvreload", objectID: "networking", user: user, duration: 2)
        case (.delete, ["network"]):
            pendingNetworks[node] = nil
            return success(nil)
        default:
            return nil
        }
    }

    // MARK: - DNS, hosts

    private func dnsSettings(_ node: String) -> [String: String] {
        nodeDNS[node] ?? ["search": "home.arpa", "dns1": "10.0.10.1", "dns2": "1.1.1.1"]
    }

    private func hostsFile(_ node: String, ip: String) -> String {
        nodeHosts[node] ?? """
        127.0.0.1 localhost.localdomain localhost
        \(ip) \(node).home.arpa \(node)

        # The following lines are desirable for IPv6 capable hosts

        ::1     ip6-localhost ip6-loopback
        fe00::0 ip6-localnet
        ff00::0 ip6-mcastprefix
        ff02::1 ip6-allnodes
        ff02::2 ip6-allrouters

        """
    }

    /// A stable stand-in for the SHA-1 digest Proxmox reports.
    private static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(format: "%016llx", hash)
    }

    private static func isIPAddress(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4 { return parts.allSatisfy { UInt8($0) != nil } }
        return text.contains(":") && text.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
    }

    // MARK: - Network

    private func activeNetwork(_ node: String) -> [DemoInterface] {
        if let interfaces = activeNetworks[node] { return interfaces }
        let ip = cluster.nodes.first { $0.name == node }?.ip ?? "10.0.10.10"
        let gateway = ip.split(separator: ".").dropLast().joined(separator: ".") + ".1"
        var interfaces = [
            DemoInterface(values: ["iface": "nic0", "type": "eth"]),
            DemoInterface(values: ["iface": "nic1", "type": "eth"]),
            DemoInterface(values: [
                "iface": "vmbr0", "type": "bridge", "autostart": "1", "cidr": "\(ip)/24", "gateway": gateway,
                "bridge_ports": "nic0", "comments": "LAN",
            ]),
        ]
        if node == cluster.nodes.first?.name {
            interfaces.append(DemoInterface(values: [
                "iface": "vmbr1", "type": "bridge", "autostart": "1", "bridge_ports": "nic1", "bridge_vlan_aware": "1",
                "bridge_vids": "2-4094", "comments": "Lab VLANs",
            ]))
        }
        return interfaces
    }

    private func pendingNetwork(_ node: String) -> [DemoInterface] {
        pendingNetworks[node] ?? activeNetwork(node)
    }

    private func interfaceJSON(_ interface: DemoInterface, node: String) -> JSONValue {
        var object = interface.values.mapValues { JSONValue.string($0) }
        let active = activeNetwork(node).contains { $0.name == interface.name }
        let isPhysical = interface.type == "eth"
        if isPhysical {
            object["exists"] = 1
            object["altnames"] = .array([.string("enp\(interface.name.dropFirst(3))s0")])
        }
        if let cidr = interface.values["cidr"] {
            let parts = cidr.split(separator: "/")
            object["address"] = .string(String(parts[0]))
            object["netmask"] = .string(parts.count > 1 ? String(parts[1]) : "24")
        }
        if active, isPhysical || interface.values["autostart"] == "1" { object["active"] = 1 }
        if let comments = interface.values["comments"] { object["comments"] = .string(comments + "\n") }
        object["method"] = interface.values["cidr"] == nil ? "manual" : "static"
        object["method6"] = interface.values["cidr6"] == nil ? "manual" : "static"
        object["families"] = ["inet"]
        return .object(object)
    }

    private func networkList(node: String, type: String?) -> HTTPResponse {
        var interfaces = pendingNetwork(node)
        switch type {
        case "any_bridge", "any_local_bridge": interfaces = interfaces.filter { $0.type == "bridge" || $0.type == "OVSBridge" }
        case let type?: interfaces = interfaces.filter { $0.type == type }
        case nil: break
        }
        var body: [String: JSONValue] = ["success": 1, "data": .array(interfaces.map { interfaceJSON($0, node: node) })]
        if let pending = pendingNetworks[node], pending != activeNetwork(node) {
            body["changes"] = .string(Self.diff(activeNetwork(node), pending))
        }
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: JSONValue.object(body).encoded())
    }

    private func createInterface(node: String, parameters: [String: String]) -> HTTPResponse {
        guard let name = parameters["iface"], !name.isEmpty else { return fieldFailure(["iface": "property is missing and it is not optional"]) }
        guard let type = parameters["type"], ["bridge", "bond", "vlan"].contains(type) else {
            return fieldFailure(["type": "value is not supported in demo mode"])
        }
        var interfaces = pendingNetwork(node)
        guard !interfaces.contains(where: { $0.name == name }) else { return fieldFailure(["iface": "Interface '\(name)' already exists"]) }
        var interface = DemoInterface(values: ["iface": name, "type": type])
        for (key, value) in parameters where Self.configKeys.contains(key) { interface.values[key] = value }
        if let error = validate(interface, in: interfaces) { return error }
        interfaces.append(interface)
        pendingNetworks[node] = interfaces
        return success(nil)
    }

    private func updateInterface(node: String, name: String, parameters: [String: String]) -> HTTPResponse {
        var interfaces = pendingNetwork(node)
        guard let index = interfaces.firstIndex(where: { $0.name == name }) else { return failure(500, "interface does not exist") }
        guard parameters["type"] == interfaces[index].type else { return fieldFailure(["type": "Changing the interface type is not possible."]) }
        var interface = interfaces[index]
        for key in (parameters["delete"] ?? "").split(separator: ",") { interface.values[String(key)] = nil }
        for (key, value) in parameters where Self.configKeys.contains(key) { interface.values[key] = value }
        if interface.values["bridge_vlan_aware"] == "1", interface.values["bridge_vids"] == nil { interface.values["bridge_vids"] = "2-4094" }
        if let error = validate(interface, in: interfaces.filter { $0.name != name }) { return error }
        interfaces[index] = interface
        pendingNetworks[node] = interfaces
        return success(nil)
    }

    /// The checks Proxmox makes that the app relies on for its error messages.
    private func validate(_ interface: DemoInterface, in others: [DemoInterface]) -> HTTPResponse? {
        if interface.values["gateway"] != nil, let owner = others.first(where: { $0.values["gateway"] != nil }) {
            return fieldFailure(["gateway": "Default gateway already exists on interface '\(owner.name)'."])
        }
        let key = interface.type == "bond" ? "slaves" : "bridge_ports"
        for member in interface.members {
            guard others.contains(where: { $0.name == member }) else { return fieldFailure([key: "No such interface '\(member)'."]) }
            if let owner = others.first(where: { $0.members.contains(member) }) {
                return fieldFailure([key: "\(member) is already used on interface '\(owner.name)'."])
            }
        }
        return nil
    }

    /// A line diff of the two configurations, in the unified format Proxmox reports.
    static func diff(_ old: [DemoInterface], _ new: [DemoInterface]) -> String {
        let header = ["auto lo", "iface lo inet loopback", ""]
        let left = header + old.flatMap(\.stanza)
        let right = header + new.flatMap(\.stanza)
        // Longest common subsequence; the files are a few dozen lines.
        var table = Array(repeating: Array(repeating: 0, count: right.count + 1), count: left.count + 1)
        for i in stride(from: left.count - 1, through: 0, by: -1) {
            for j in stride(from: right.count - 1, through: 0, by: -1) {
                table[i][j] = left[i] == right[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var lines = ["--- /etc/network/interfaces", "+++ /etc/network/interfaces.new", "@@ -1,\(left.count) +1,\(right.count) @@"]
        var i = 0, j = 0
        while i < left.count || j < right.count {
            if i < left.count, j < right.count, left[i] == right[j] {
                lines.append(" " + left[i]); i += 1; j += 1
            } else if j < right.count, i == left.count || table[i][j + 1] >= table[i + 1][j] {
                lines.append("+" + right[j]); j += 1
            } else {
                lines.append("-" + left[i]); i += 1
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
