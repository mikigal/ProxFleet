import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

/// Firewall rules, options, aliases and IP sets, with responses recorded from Proxmox VE 9.2.
struct FirewallTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func paths() {
        let guest = GuestReference(node: "pve", vmid: 100, kind: .virtualMachine)
        #expect(PVE.firewallRules(.datacenter).path == "/cluster/firewall/rules")
        #expect(PVE.firewallRules(.group("web-servers")).path == "/cluster/firewall/groups/web-servers")
        #expect(PVE.firewallOptions(.node("pve")).path == "/nodes/pve/firewall/options")
        #expect(PVE.firewallReferences(.guest(guest)).path == "/nodes/pve/qemu/100/firewall/refs")
        // Nodes and security groups use the datacenter's aliases and IP sets.
        #expect(PVE.firewallReferences(.node("pve")).path == "/cluster/firewall/refs")
        #expect(PVE.deleteFirewallIPSetEntry(.datacenter, set: "lan", cidr: "10.0.0.0/8").path == "/cluster/firewall/ipset/lan/10.0.0.0%2F8")
        #expect(FirewallScope.guest(guest).aclPath == "/vms/100" && FirewallScope.guest(guest).modifyPrivilege == "VM.Config.Network")
        #expect(FirewallScope.guest(guest).directions == [.in, .out] && FirewallScope.node("pve").directions.contains(.forward))
        #expect(!FirewallScope.node("pve").hasAliasesAndIPSets && FirewallScope.node("pve").hasLog && !FirewallScope.group("g").hasOptions)
    }

    @Test func rules() throws {
        let rules = try decode([FirewallRule].self, #"""
        [{"digest": "4f32b2", "pos": 0, "action": "probe_grp2", "enable": 0, "type": "group"},
         {"proto": "tcp", "enable": 1, "digest": "4f32b2", "type": "in", "dport": "8006,22", "action": "ACCEPT", "source": "+probe_set",
          "errors": {"source": "no such ipset 'probe_set'"}, "pos": 1, "log": "info", "comment": "web ui"},
         {"macro": "Ping", "type": "in", "enable": 0, "action": "DROP", "pos": 2, "digest": "4f32b2", "log": "nolog"},
         {"enable": 0, "iface": "net0", "proto": "icmpv6", "action": "REJECT", "icmp-type": "echo-request", "type": "out", "dest": "probe_guest",
          "pos": 3, "ipversion": 6}]
        """#)
        #expect(rules[0].isGroup && rules[0].action == "probe_grp2" && !rules[0].isEnabled)
        #expect(rules[1].errors == ["source": "no such ipset 'probe_set'"] && rules[1].destinationPort == "8006,22" && rules[1].logLevel == "info")
        #expect(rules[2].macro == "Ping" && rules[2].logLevel == nil && rules[2].errors.isEmpty)
        #expect(rules[3].icmpType == "echo-request" && rules[3].interface == "net0" && rules[3].ipVersion == 6)

        let group = FirewallRuleDraft(rules[0])
        #expect(group.group == "probe_grp2" && group.isGroup && group.changes(from: group).isEmpty)
        let icmp = FirewallRuleDraft(rules[3])
        #expect(icmp.isICMP && !icmp.takesPorts && icmp.serialized()["icmp-type"] == "echo-request")
    }

    @Test func choosingAMacroClearsProtocolAndPorts() throws {
        let rule = try decode(FirewallRule.self, #"{"pos": 1, "type": "in", "action": "ACCEPT", "proto": "tcp", "dport": "8006", "sport": "1024:65535", "enable": 1, "log": "info"}"#)
        let original = FirewallRuleDraft(rule)
        var draft = original
        draft.macro = "HTTPS"
        draft.logLevel = "nolog"
        let update = draft.changes(from: original)
        #expect(update.values == ["macro": "HTTPS"])
        #expect(update.deletions == ["dport", "log", "proto", "sport"])

        var group = original
        group.type = "group"
        group.group = "webserver"
        group.comment = "Web"
        let switched = group.changes(from: original)
        #expect(switched.values == ["action": "webserver", "comment": "Web", "type": "group"])
        #expect(switched.deletions == ["dport", "log", "proto", "sport"])
    }

    @Test func creationParametersAndProblems() {
        var draft = FirewallRuleDraft()
        draft.proto = "tcp"
        draft.destinationPort = "22"
        draft.source = "+management"
        draft.comment = "SSH"
        #expect(draft.problems.isEmpty)
        #expect(PVE.createFirewallRule(.datacenter, draft).parameters.formEncoded
            == "action=ACCEPT&comment=SSH&dport=22&enable=1&proto=tcp&source=%2Bmanagement&type=in")

        var missing = FirewallRuleDraft()
        missing.destinationPort = "443"
        #expect(missing.problems.keys.sorted() == ["proto"])
        missing.type = "forward"
        missing.action = "REJECT"
        missing.proto = "tcp"
        #expect(missing.problems.keys.sorted() == ["action"])
        var group = FirewallRuleDraft()
        group.type = "group"
        #expect(group.problems.keys.sorted() == ["action"])
    }

    @Test func moving() {
        let request = PVE.moveFirewallRule(.node("pve"), position: 0, to: 3, digest: "abc")
        #expect(request.method == .put && request.path == "/nodes/pve/firewall/rules/0" && request.parameters.formEncoded == "moveto=3&digest=abc")
        #expect(PVE.deleteFirewallRule(.datacenter, position: 2, digest: "abc").parameters.formEncoded == "digest=abc")
    }

    @Test func options() throws {
        let stored = try decode(FirewallOptions.self, #"{"enable": 1, "policy_in": "DROP", "digest": "b5b4b3", "log_ratelimit": "enable=1,burst=10"}"#)
        #expect(stored.values == ["enable": "1", "policy_in": "DROP", "log_ratelimit": "enable=1,burst=10"] && stored.digest == "b5b4b3")
        #expect(stored.isEnabled(in: .datacenter))
        let empty = try decode(FirewallOptions.self, #"{"digest": "da39a3"}"#)
        // Nodes filter by default once the datacenter firewall is on; guests and the datacenter do not.
        #expect(empty.isEnabled(in: .node("pve")) && !empty.isEnabled(in: .datacenter))

        let original = FirewallOptionsDraft(stored, scope: .datacenter)
        // The input policy is stored but equals the default, so it is not a change.
        #expect(original.choice("policy_in") == "DROP" && original.serialized()["policy_in"] == .some(nil))
        #expect(original.rateLimit.burst == 10 && original.flag("ebtables"))
        var draft = original
        draft.setFlag("enable", false)
        draft.values["policy_out"] = "REJECT"
        draft.rateLimit.burst = 5
        let update = draft.changes(from: original)
        #expect(update.values == ["policy_out": "REJECT"])
        #expect(update.deletions == ["enable", "log_ratelimit"])

        var node = FirewallOptionsDraft(empty, scope: .node("pve"))
        let nodeOriginal = node
        node.setMembers("nf_conntrack_helpers", ["sip", "ftp"])
        node.values["nf_conntrack_max"] = "100"
        #expect(node.problems.keys.sorted() == ["nf_conntrack_max"])
        node.values["nf_conntrack_max"] = "131072"
        #expect(node.changes(from: nodeOriginal).values == ["nf_conntrack_helpers": "ftp,sip", "nf_conntrack_max": "131072"])

        let guest = FirewallOptionsDraft(empty, scope: .guest(GuestReference(node: "pve", vmid: 100, kind: .container)))
        #expect(guest.flag("dhcp") && guest.flag("macfilter") && !guest.flag("ipfilter") && guest.choice("policy_in") == "DROP")
    }

    @Test func aliasesIPSetsAndReferences() throws {
        let aliases = try decode([FirewallAlias].self, #"[{"cidr": "192.168.0.0/16", "name": "probe_lan2", "digest": "6aac3c", "ipversion": 4}]"#)
        #expect(aliases[0].name == "probe_lan2" && aliases[0].comment == nil && aliases[0].ipVersion == 4)
        #expect(PVE.updateFirewallAlias(.datacenter, name: "lan", newName: "home", cidr: "10.0.0.0/8", comment: "", digest: "d").parameters.formEncoded
            == "cidr=10.0.0.0%2F8&comment=&rename=home&digest=d")

        let entries = try decode([FirewallIPSetEntry].self, #"""
        [{"cidr": "10.0.0.1", "nomatch": 1, "digest": "9e7042"},
         {"errors": {"cidr": "no such alias 'probe_lan'"}, "digest": "9e7042", "cidr": "probe_lan", "comment": "one"}]
        """#)
        #expect(entries[0].isExcluded && entries[1].errors["cidr"] != nil && entries[1].comment == "one")
        // Renaming sends the new name as `name` and the old one as `rename`.
        #expect(PVE.saveFirewallIPSet(.datacenter, name: "new", comment: "", renaming: "old").parameters.formEncoded == "name=new&comment=&rename=old")
        #expect(PVE.saveFirewallIPSet(.datacenter, name: "new", comment: "").parameters.formEncoded == "name=new")
        #expect(PVE.saveFirewallGroup(name: "web", comment: "x", renaming: "www").parameters.formEncoded == "group=web&comment=x&rename=www")

        let references = try decode([FirewallReference].self, #"""
        [{"type": "ipset", "scope": "dc", "ref": "+probe_set", "name": "probe_set", "comment": "probeset"},
         {"ref": "probe_guest", "name": "probe_guest", "scope": "guest", "type": "alias"}]
        """#)
        #expect(references[0].isIPSet && references[0].reference == "+probe_set" && references[1].scope == "guest" && !references[1].isIPSet)
    }

    @Test func log() throws {
        let empty = try decode(FirewallLog.self, #"{"data": [{"n": 1, "t": "no content"}], "total": 1}"#)
        #expect(empty.lines.isEmpty && empty.total == 0)
        let log = try decode(FirewallLog.self, #"{"data": [{"n": 1, "t": "0 5 - 21/Oct/2026:00:27:41 +0200 starting pvefw logger"}], "total": 10}"#)
        #expect(log.lines.first?.number == 1 && log.total == 10)
    }
}
