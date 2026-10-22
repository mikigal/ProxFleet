import Foundation
import ProxmoxCore

/// One firewall configuration file in demo mode: the datacenter's, a node's or a guest's.
struct DemoFirewallConfig: Sendable {
    struct IPSet: Sendable {
        var name: String
        var comment: String?
        var entries: [[String: String]]
    }

    var options: [String: String] = [:]
    var rules: [[String: String]] = []
    /// Name, CIDR and comment, in the order they were added.
    var aliases: [(name: String, cidr: String, comment: String?)] = []
    var ipSets: [IPSet] = []
    var revision = 1
}

struct DemoSecurityGroup: Sendable {
    var name: String
    var comment: String?
    var rules: [[String: String]]
    var revision = 1
}

/// The firewall of the demo cluster: configurations by `dc`, `node/{name}` and `guest/{vmid}`, plus security groups.
struct DemoFirewall: Sendable {
    var configs: [String: DemoFirewallConfig]
    var groups: [DemoSecurityGroup]

    static let macros: [(String, String)] = [
        ("DNS", "Domain Name System traffic (udp and tcp)"), ("FTP", "File Transfer Protocol"), ("HTTP", "Hypertext Transfer Protocol (WWW)"),
        ("HTTPS", "Hypertext Transfer Protocol (WWW) over SSL"), ("IMAPS", "Internet Message Access Protocol over SSL"),
        ("LDAP", "Lightweight Directory Access Protocol traffic"), ("MySQL", "MySQL server"), ("NTP", "Network Time Protocol (ntpd)"),
        ("Ping", "ICMP echo request"), ("PostgreSQL", "PostgreSQL server"), ("RDP", "Microsoft Remote Desktop Protocol traffic"),
        ("SMB", "Microsoft SMB traffic"), ("SMTP", "Simple Mail Transfer Protocol"), ("SNMP", "Simple Network Management Protocol"),
        ("SSH", "Secure shell traffic"), ("Syslog", "Syslog protocol (RFC 5424) traffic"), ("VNC", "VNC traffic for VNC display's 0 - 99"),
        ("Web", "WWW traffic (HTTP and HTTPS)"),
    ]

    static func sample(for cluster: DemoCluster) -> DemoFirewall {
        let network = cluster.nodes.first.map { $0.ip.split(separator: ".").prefix(3).joined(separator: ".") } ?? "10.0.10"
        var datacenter = DemoFirewallConfig()
        datacenter.options = ["enable": "1"]
        datacenter.aliases = [("lan", "\(network).0/24", "Home network"), ("admin-laptop", "\(network).50", nil)]
        datacenter.ipSets = [
            .init(name: "management", comment: "Web interface and SSH", entries: [["cidr": "lan"]]),
            .init(name: "blacklist", comment: "Scanners", entries: [["cidr": "203.0.113.0/24", "comment": "Seen probing SSH"]]),
        ]
        datacenter.rules = [
            ["type": "in", "action": "ACCEPT", "macro": "Ping", "source": "lan", "enable": "1", "comment": "Ping from the home network"],
            ["type": "in", "action": "ACCEPT", "proto": "tcp", "dport": "8006", "source": "+management", "enable": "1", "comment": "Web interface"],
            ["type": "group", "action": "ssh-admin", "enable": "1"],
        ]
        var configs = ["dc": datacenter]
        if let node = cluster.nodes.first {
            var host = DemoFirewallConfig()
            host.rules = [["type": "in", "action": "ACCEPT", "proto": "tcp", "dport": "9100", "source": "lan", "enable": "1", "comment": "Prometheus node exporter"]]
            configs["node/\(node.name)"] = host
        }
        if let vm = cluster.guests.first(where: { $0.kind == .qemu && !$0.isTemplate }) {
            var guest = DemoFirewallConfig()
            guest.options = ["enable": "1", "policy_in": "DROP"]
            guest.rules = [
                ["type": "in", "action": "ACCEPT", "macro": "SSH", "source": "admin-laptop", "enable": "1", "log": "info"],
                ["type": "group", "action": "webserver", "enable": "1", "iface": "net0"],
                ["type": "in", "action": "ACCEPT", "proto": "tcp", "dport": "8123", "source": "lan", "enable": "0", "comment": "Old dashboard port"],
            ]
            guest.aliases = [("tablet", "\(network).80", "Wall tablet")]
            configs["guest/\(vm.vmid)"] = guest
        }
        return DemoFirewall(configs: configs, groups: [
            DemoSecurityGroup(name: "webserver", comment: "HTTP and HTTPS", rules: [
                ["type": "in", "action": "ACCEPT", "macro": "HTTPS", "enable": "1"],
                ["type": "in", "action": "ACCEPT", "macro": "HTTP", "enable": "1"],
            ]),
            DemoSecurityGroup(name: "ssh-admin", comment: "SSH from the admin laptop", rules: [
                ["type": "in", "action": "ACCEPT", "macro": "SSH", "source": "admin-laptop", "enable": "1"],
            ]),
        ])
    }
}

/// `/cluster/firewall`, `/nodes/{node}/firewall` and `/nodes/{node}/{qemu|lxc}/{vmid}/firewall` in demo mode.
extension DemoState {
    private static let ruleKeys: Set<String> = ["type", "action", "macro", "source", "dest", "proto", "dport", "sport", "icmp-type", "iface", "log", "comment", "enable"]
    private static let conflictMessage = "detected modified configuration - file changed by other user? Try again."

    /// Routes below the firewall paths. nil for other paths.
    func handleFirewall(_ method: HTTPMethod, parts: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        let key: String
        let rest: [String]
        if parts.count >= 2, parts[0] == "cluster", parts[1] == "firewall" {
            key = "dc"
            rest = Array(parts.dropFirst(2))
        } else if parts.count >= 3, parts[0] == "nodes", parts[2] == "firewall" {
            key = "node/\(parts[1])"
            rest = Array(parts.dropFirst(3))
        } else if parts.count >= 5, parts[0] == "cluster", parts[1] == "sdn", parts[2] == "vnets", parts[4] == "firewall" {
            guard sdn.vnets.contains(where: { $0.id == parts[3] }) else { return failure(500, "sdn vnet object '\(parts[3])' does not exist") }
            key = "vnet/\(parts[3])"
            rest = Array(parts.dropFirst(5))
        } else if parts.count >= 5, parts[0] == "nodes", ["qemu", "lxc"].contains(parts[2]), parts[4] == "firewall", let vmid = Int(parts[3]) {
            guard cluster.guests.contains(where: { $0.vmid == vmid }) else { return failure(500, "Configuration file 'nodes/\(parts[1])/\(parts[2])/\(vmid).conf' does not exist") }
            key = "guest/\(vmid)"
            rest = Array(parts.dropFirst(5))
        } else {
            return nil
        }
        let isGuest = key.hasPrefix("guest/")
        if method != .get {
            let needed = isGuest ? "VM.Config.Network" : key.hasPrefix("vnet/") ? "SDN.Allocate" : "Sys.Modify"
            guard privileges(for: user).contains(needed) else {
                let path = isGuest ? "/vms/\(key.dropFirst(6))" : key == "dc" ? "/" : "/nodes/\(key.dropFirst(5))"
                return failure(403, "Permission check failed (\(path), \(needed))")
            }
        }
        if key == "dc", rest.first == "groups" {
            return handleSecurityGroups(method, rest: Array(rest.dropFirst()), parameters: parameters)
        }
        var config = firewall.configs[key] ?? DemoFirewallConfig()
        let digest = Self.digest(key, config.revision)
        if method != .get, let sent = parameters["digest"], sent != digest { return failure(500, Self.conflictMessage) }

        let response: HTTPResponse
        switch (method, rest) {
        case (.get, []):
            let names = key == "dc" ? ["aliases", "rules", "options", "groups", "ipset", "macros", "refs"]
                : isGuest ? ["rules", "aliases", "ipset", "refs", "options", "log"] : ["rules", "options", "log"]
            return success(.array(names.map { ["name": .string($0)] }))
        case (.get, ["macros"]) where key == "dc":
            return success(.array(DemoFirewall.macros.map { ["macro": .string($0.0), "descr": .string($0.1)] }))
        case (.get, ["refs"]):
            return success(.array(references(for: key)))
        case (.get, ["log"]) where key != "dc":
            return firewallLog(for: key, parameters: parameters)
        case (.get, ["options"]):
            var object = config.options.mapValues { value in Int(value).map(JSONValue.int) ?? .string(value) }
            object["digest"] = .string(digest)
            return success(.object(object))
        case (.put, ["options"]):
            for name in (parameters["delete"] ?? "").split(separator: ",") { config.options[String(name)] = nil }
            for (name, value) in parameters where !["delete", "digest"].contains(name) { config.options[name] = value }
            response = success(nil)
        case (.get, ["rules"]):
            return success(.array(config.rules.enumerated().map { ruleJSON($1, position: $0, digest: digest, scope: key) }))
        case (.post, ["rules"]):
            switch validatedRule(parameters, base: [:], scope: key) {
            case .failure(let failure): return failure.response
            case .success(let rule): config.rules.insert(rule, at: min(Int(parameters["pos"] ?? "") ?? 0, config.rules.count))
            }
            response = success(nil)
        case (_, let path) where path.count == 2 && path[0] == "rules":
            guard let position = Int(path[1]), config.rules.indices.contains(position) else { return failure(500, "no rule at position \(path[1])") }
            switch method {
            case .get:
                return success(ruleJSON(config.rules[position], position: position, digest: digest, scope: key))
            case .delete:
                config.rules.remove(at: position)
            default:
                if let error = updateRule(&config.rules, at: position, parameters: parameters, scope: key) { return error }
            }
            response = success(nil)
        case (.get, ["aliases"]):
            return success(.array(config.aliases.map { alias in
                var object: [String: JSONValue] = ["name": .string(alias.name), "cidr": .string(alias.cidr), "digest": .string(digest),
                                                   "ipversion": .int(alias.cidr.contains(":") ? 6 : 4)]
                if let comment = alias.comment { object["comment"] = .string(comment) }
                return .object(object)
            }))
        case (.post, ["aliases"]):
            guard let name = parameters["name"], Self.isValidName(name) else { return fieldFailure(["name": "value does not match the regex pattern"]) }
            guard let cidr = parameters["cidr"], Self.isAddress(cidr) else { return fieldFailure(["cidr": "invalid format - value does not look like a valid IP address or CIDR network"]) }
            guard !config.aliases.contains(where: { $0.name.lowercased() == name.lowercased() }) else { return fieldFailure(["name": "alias '\(name)' already exists"]) }
            config.aliases.append((name, cidr, parameters["comment"]?.nilIfEmpty))
            response = success(nil)
        case (_, let path) where path.count == 2 && path[0] == "aliases":
            guard let index = config.aliases.firstIndex(where: { $0.name == path[1] }) else { return failure(500, "no such alias '\(path[1])'") }
            switch method {
            case .get:
                return success(["name": .string(config.aliases[index].name), "cidr": .string(config.aliases[index].cidr), "digest": .string(digest)])
            case .delete:
                config.aliases.remove(at: index)
            default:
                guard let cidr = parameters["cidr"], Self.isAddress(cidr) else { return fieldFailure(["cidr": "invalid format - value does not look like a valid IP address or CIDR network"]) }
                if let rename = parameters["rename"], rename != path[1] {
                    guard Self.isValidName(rename) else { return fieldFailure(["rename": "value does not match the regex pattern"]) }
                    guard !config.aliases.contains(where: { $0.name == rename }) else { return fieldFailure(["name": "alias '\(rename)' already exists"]) }
                    config.aliases[index].name = rename
                }
                config.aliases[index].cidr = cidr
                if let comment = parameters["comment"] { config.aliases[index].comment = comment.nilIfEmpty }
            }
            response = success(nil)
        case (.get, ["ipset"]):
            return success(.array(config.ipSets.map { set in
                var object: [String: JSONValue] = ["name": .string(set.name), "digest": .string(digest)]
                if let comment = set.comment { object["comment"] = .string(comment) }
                return .object(object)
            }))
        case (.post, ["ipset"]):
            guard let name = parameters["name"], Self.isValidName(name) else { return fieldFailure(["name": "value does not match the regex pattern"]) }
            if let old = parameters["rename"] {
                guard let index = config.ipSets.firstIndex(where: { $0.name == old }) else { return failure(500, "IPSet '\(old)' does not exist") }
                if name != old, config.ipSets.contains(where: { $0.name == name }) { return failure(500, "IPSet '\(name)' already exists") }
                config.ipSets[index].name = name
                if let comment = parameters["comment"] { config.ipSets[index].comment = comment.nilIfEmpty }
            } else {
                guard !config.ipSets.contains(where: { $0.name == name }) else { return failure(500, "IPSet '\(name)' already exists") }
                config.ipSets.append(.init(name: name, comment: parameters["comment"]?.nilIfEmpty, entries: []))
            }
            response = success(nil)
        case (_, let path) where path.count >= 2 && path[0] == "ipset":
            guard let index = config.ipSets.firstIndex(where: { $0.name == path[1] }) else { return failure(500, "no such IPSet '\(path[1])'") }
            // The path arrives decoded, so a network's slash splits it in two.
            let cidr = path.count > 2 ? path.dropFirst(2).joined(separator: "/") : nil
            switch (method, cidr) {
            case (.get, nil):
                return success(.array(config.ipSets[index].entries.map { entry in
                    var object = entry.mapValues { JSONValue.string($0) }
                    object["nomatch"] = entry["nomatch"].map { .int(Int($0) ?? 0) }
                    object["digest"] = .string(digest)
                    if let value = entry["cidr"], !Self.isAddress(value), !referenceExists(value, scope: key) {
                        object["errors"] = ["cidr": .string("no such alias '\(value)'")]
                    }
                    return .object(object)
                }))
            case (.post, nil):
                guard let value = parameters["cidr"], Self.isAddress(value) || referenceExists(value, scope: key) else {
                    return fieldFailure(["cidr": "invalid format - value does not look like a valid IP address or CIDR network"])
                }
                guard !config.ipSets[index].entries.contains(where: { $0["cidr"] == value }) else { return failure(500, "address '\(value)' already exists") }
                var entry = ["cidr": value]
                if let comment = parameters["comment"]?.nilIfEmpty { entry["comment"] = comment }
                if parameters["nomatch"] == "1" { entry["nomatch"] = "1" }
                config.ipSets[index].entries.append(entry)
            case (.delete, nil):
                guard config.ipSets[index].entries.isEmpty || parameters["force"] == "1" else { return failure(500, "IPSet '\(path[1])' is not empty") }
                config.ipSets.remove(at: index)
            case (_, let cidr?):
                guard let entry = config.ipSets[index].entries.firstIndex(where: { $0["cidr"] == cidr }) else { return failure(500, "no such IP/Network") }
                if method == .delete {
                    config.ipSets[index].entries.remove(at: entry)
                } else {
                    if let comment = parameters["comment"] { config.ipSets[index].entries[entry]["comment"] = comment.nilIfEmpty }
                    if let nomatch = parameters["nomatch"] { config.ipSets[index].entries[entry]["nomatch"] = nomatch == "1" ? "1" : nil }
                }
            default:
                return nil
            }
            response = success(nil)
        default:
            return nil
        }
        config.revision += 1
        firewall.configs[key] = config
        return response
    }

    private func handleSecurityGroups(_ method: HTTPMethod, rest: [String], parameters: [String: String]) -> HTTPResponse? {
        switch (method, rest) {
        case (.get, []):
            return success(.array(firewall.groups.map { group in
                var object: [String: JSONValue] = ["group": .string(group.name), "digest": .string(Self.digest(group.name, group.revision))]
                if let comment = group.comment { object["comment"] = .string(comment) }
                return .object(object)
            }))
        case (.post, []):
            guard let name = parameters["group"], Self.isValidName(name), name.count <= 18 else { return fieldFailure(["group": "value does not match the regex pattern"]) }
            if let old = parameters["rename"] {
                guard let index = firewall.groups.firstIndex(where: { $0.name == old }) else { return failure(500, "Security group '\(old)' does not exist") }
                if name != old, firewall.groups.contains(where: { $0.name == name }) { return failure(500, "Security group '\(name)' already exists") }
                firewall.groups[index].name = name
                if let comment = parameters["comment"] { firewall.groups[index].comment = comment.nilIfEmpty }
                // Renaming updates the rules that apply the group, as on a real server.
                for (key, var config) in firewall.configs {
                    for position in config.rules.indices where config.rules[position]["type"] == "group" && config.rules[position]["action"] == old {
                        config.rules[position]["action"] = name
                    }
                    firewall.configs[key] = config
                }
            } else {
                guard !firewall.groups.contains(where: { $0.name == name }) else { return failure(500, "Security group '\(name)' already exists") }
                firewall.groups.append(DemoSecurityGroup(name: name, comment: parameters["comment"]?.nilIfEmpty, rules: []))
            }
            return success(nil)
        default:
            break
        }
        guard let name = rest.first, let index = firewall.groups.firstIndex(where: { $0.name == name }) else {
            return failure(500, "no such security group '\(rest.first ?? "")'")
        }
        let digest = Self.digest(name, firewall.groups[index].revision)
        if method != .get, let sent = parameters["digest"], sent != digest { return failure(500, Self.conflictMessage) }
        switch (method, Array(rest.dropFirst())) {
        case (.get, []):
            return success(.array(firewall.groups[index].rules.enumerated().map { ruleJSON($1, position: $0, digest: digest, scope: "dc") }))
        case (.post, []):
            switch validatedRule(parameters, base: [:], scope: "dc", inGroup: true) {
            case .failure(let failure): return failure.response
            case .success(let rule): firewall.groups[index].rules.insert(rule, at: min(Int(parameters["pos"] ?? "") ?? 0, firewall.groups[index].rules.count))
            }
        case (.delete, []):
            guard firewall.groups[index].rules.isEmpty else { return failure(500, "Security group '\(name)' is not empty") }
            firewall.groups.remove(at: index)
            return success(nil)
        case (_, let path) where path.count == 1:
            guard let position = Int(path[0]), firewall.groups[index].rules.indices.contains(position) else { return failure(500, "no rule at position \(path[0])") }
            switch method {
            case .get:
                return success(ruleJSON(firewall.groups[index].rules[position], position: position, digest: digest, scope: "dc"))
            case .delete:
                firewall.groups[index].rules.remove(at: position)
            default:
                if let error = updateRule(&firewall.groups[index].rules, at: position, parameters: parameters, scope: "dc", inGroup: true) { return error }
            }
        default:
            return nil
        }
        firewall.groups[index].revision += 1
        return success(nil)
    }

    // MARK: - Rules

    private struct RuleFailure: Error {
        var response: HTTPResponse
    }

    /// Applies `moveto`, or the changed settings, to the rule at `position`. Returns an error response, or nil.
    private func updateRule(_ rules: inout [[String: String]], at position: Int, parameters: [String: String], scope: String, inGroup: Bool = false) -> HTTPResponse? {
        if let target = parameters["moveto"].flatMap({ Int($0) }) {
            // Moves the rule in front of the one now at `moveto`, as the real server does.
            let rule = rules.remove(at: position)
            rules.insert(rule, at: min(target > position ? target - 1 : target, rules.count))
            return nil
        }
        var base = rules[position]
        for name in (parameters["delete"] ?? "").split(separator: ",") { base[String(name)] = nil }
        switch validatedRule(parameters, base: base, scope: scope, inGroup: inGroup) {
        case .failure(let failure): return failure.response
        case .success(let rule): rules[position] = rule
        }
        return nil
    }

    private func validatedRule(_ parameters: [String: String], base: [String: String], scope: String, inGroup: Bool = false) -> Result<[String: String], RuleFailure> {
        var rule = base
        for (name, value) in parameters where Self.ruleKeys.contains(name) { rule[name] = value.isEmpty ? nil : value }
        func invalid(_ errors: [String: String]) -> Result<[String: String], RuleFailure> { .failure(RuleFailure(response: fieldFailure(errors))) }
        guard let type = rule["type"], ["in", "out", "forward", "group"].contains(type) else { return invalid(["type": "value '\(rule["type"] ?? "")' does not have a value in the enumeration 'in, out, forward, group'"]) }
        guard let action = rule["action"] else { return invalid(["action": "property is missing and it is not optional"]) }
        if type == "group" {
            if inGroup { return invalid(["type": "security groups cannot contain group rules"]) }
            guard firewall.groups.contains(where: { $0.name == action }) else { return invalid(["action": "no such security group '\(action)'"]) }
        } else {
            guard ["ACCEPT", "DROP", "REJECT"].contains(action) else { return invalid(["action": "value '\(action)' does not have a value in the enumeration 'ACCEPT, DROP, REJECT'"]) }
            if type == "forward", action == "REJECT" { return invalid(["action": "Forward rules only allow ACCEPT and DROP"]) }
        }
        if let macro = rule["macro"], !DemoFirewall.macros.contains(where: { $0.0.lowercased() == macro.lowercased() }) {
            return invalid(["macro": "unknown macro '\(macro)'"])
        }
        for key in ["source", "dest"] {
            guard let value = rule[key] else { continue }
            for item in value.split(separator: ",").map(String.init) where !Self.isAddress(item) && !referenceExists(item, scope: scope) {
                return invalid([key: item.hasPrefix("+") ? "no such ipset '\(item.dropFirst())'" : "no such alias '\(item)'"])
            }
        }
        for key in ["dport", "sport"] {
            guard let value = rule[key] else { continue }
            if rule["proto"] == nil { return invalid(["proto": "missing property - '\(key)' requires this property"]) }
            for port in value.split(whereSeparator: { $0 == "," || $0 == ":" }) {
                if let number = Int(port), !(0...65535).contains(number) { return invalid([key: "invalid format - invalid port '\(port)'"]) }
            }
        }
        if rule["enable"] == nil { rule["enable"] = "0" }
        return .success(rule)
    }

    private func ruleJSON(_ rule: [String: String], position: Int, digest: String, scope: String) -> JSONValue {
        var object = rule.mapValues { JSONValue.string($0) }
        object["enable"] = .int(rule["enable"] == "1" ? 1 : 0)
        object["pos"] = .int(position)
        object["digest"] = .string(digest)
        var errors: [String: JSONValue] = [:]
        for key in ["source", "dest"] {
            guard let value = rule[key] else { continue }
            if let missing = value.split(separator: ",").map(String.init).first(where: { !Self.isAddress($0) && !referenceExists($0, scope: scope) }) {
                errors[key] = .string(missing.hasPrefix("+") ? "no such ipset '\(missing.dropFirst())'" : "no such alias '\(missing)'")
            }
        }
        if !errors.isEmpty { object["errors"] = .object(errors) }
        return .object(object)
    }

    // MARK: - References and log

    private func references(for scope: String) -> [JSONValue] {
        var result: [JSONValue] = []
        func add(_ config: DemoFirewallConfig?, scope name: String) {
            for set in config?.ipSets ?? [] {
                var object: [String: JSONValue] = ["type": "ipset", "name": .string(set.name), "ref": .string("+\(set.name)"), "scope": .string(name)]
                if let comment = set.comment { object["comment"] = .string(comment) }
                result.append(.object(object))
            }
            for alias in config?.aliases ?? [] {
                var object: [String: JSONValue] = ["type": "alias", "name": .string(alias.name), "ref": .string(alias.name), "scope": .string(name)]
                if let comment = alias.comment { object["comment"] = .string(comment) }
                result.append(.object(object))
            }
        }
        add(firewall.configs["dc"], scope: "dc")
        if scope.hasPrefix("guest/") { add(firewall.configs[scope], scope: "guest") }
        return result
    }

    private func referenceExists(_ reference: String, scope: String) -> Bool {
        let configs = [firewall.configs["dc"], scope.hasPrefix("guest/") ? firewall.configs[scope] : nil].compactMap { $0 }
        if reference.hasPrefix("+") {
            let name = reference.dropFirst()
            return configs.contains { $0.ipSets.contains { $0.name == name } }
        }
        return configs.contains { $0.aliases.contains { $0.name.lowercased() == reference.lowercased() } }
    }

    private func firewallLog(for scope: String, parameters: [String: String]) -> HTTPResponse {
        let network = cluster.nodes.first.map { $0.ip.split(separator: ".").prefix(3).joined(separator: ".") } ?? "10.0.10"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd/MMM/yyyy:HH:mm:ss Z"
        let vmid = scope.hasPrefix("guest/") ? String(scope.dropFirst(6)) : "0"
        let chain = vmid == "0" ? "PVEFW-HOST-IN" : "tap\(vmid)i0-IN"
        let ports = [22, 443, 3389, 23, 8080, 22, 5900, 445]
        var lines = [(vmid, "5 - \(formatter.string(from: started.addingTimeInterval(-7200))) starting pvefw logger")]
        for index in 0..<24 {
            let time = formatter.string(from: started.addingTimeInterval(Double(index * 240 - 6000)))
            let source = index % 3 == 0 ? "203.0.113.\(17 + index)" : "\(network).\(60 + index % 7)"
            let port = ports[index % ports.count]
            lines.append((vmid, "6 \(chain) \(time) policy DROP: IN=vmbr0 SRC=\(source) DST=\(network).20 LEN=60 TTL=\(index % 2 == 0 ? 64 : 52) PROTO=TCP SPT=\(40000 + index * 37) DPT=\(port) SYN"))
        }
        let start = Int(parameters["start"] ?? "") ?? 0
        let limit = Int(parameters["limit"] ?? "") ?? 50
        let slice = lines.enumerated().dropFirst(start).prefix(limit)
        let body: JSONValue = [
            "data": .array(slice.map { ["n": .int($0.offset + 1), "t": .string("\($0.element.0) \($0.element.1)")] }),
            "total": .int(lines.count), "success": 1,
        ]
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body.encoded())
    }

    // MARK: - Helpers

    private static func digest(_ key: String, _ revision: Int) -> String {
        let seed = key.unicodeScalars.reduce(UInt64(revision) &* 2_654_435_761) { $0 &* 31 &+ UInt64($1.value) }
        return String(format: "%016llx%016llx%08x", seed, seed &* 6_364_136_223_846_793_005, revision)
    }

    private static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z][A-Za-z0-9\-_]+/) != nil
    }

    /// An IP address, a network in CIDR notation, or a range, as opposed to the name of an alias or IP set.
    static func isAddress(_ text: String) -> Bool {
        let address = text.split(separator: "/").first.map(String.init) ?? text
        if address.contains(":") { return address.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "-" } }
        let parts = address.split(separator: "-").first?.split(separator: ".", omittingEmptySubsequences: false) ?? []
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
