import Foundation
@testable import PVEKit
import ProxmoxCore
import Testing

/// DNS, hosts, time and network settings, with responses recorded from Proxmox VE 9.2.
struct NodeSystemTests {
    private func response(_ json: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
    }

    @Test func dnsKeepsServersInOrder() throws {
        let dns = try JSONDecoder().decode(NodeDNS.self, from: Data(#"{"search": "local", "dns1": "10.10.100.111"}"#.utf8))
        #expect(dns.searchDomain == "local")
        #expect(dns.servers == ["10.10.100.111", "", ""])

        var edited = dns
        edited.servers = ["", " 1.1.1.1 ", "9.9.9.9"]
        let parameters = PVE.updateNodeDNS("pve", edited).parameters
        #expect(parameters.formEncoded == "search=local&dns1=1.1.1.1&dns2=9.9.9.9")
    }

    @Test func nodeOptionsKeepUnknownWakeOnLANKeysAndOnlySendChanges() throws {
        // Recorded after setting notes and options in the web interface.
        let json = #"{"startall-onboot-delay":"5","wakeonlan":"AA:BB:CC:DD:EE:01,bind-interface=vmbr0,broadcast-address=10.10.100.255","description":"Test **notes**\nline 2\n","digest":"e6c82288586090452411c34dd8fdab02413d8a95","ballooning-target":"70"}"#
        let options = try JSONDecoder().decode(NodeOptions.self, from: Data(json.utf8))
        #expect(options.notes == "Test **notes**\nline 2")
        #expect(options.wakeOnLANAddress == "AA:BB:CC:DD:EE:01")
        #expect(options.digest == "e6c82288586090452411c34dd8fdab02413d8a95" && options.values["digest"] == nil)

        let original = NodeOptionsDraft(options)
        #expect(original.bindInterface == "vmbr0" && original.broadcastAddress == "10.10.100.255" && original.startDelay == "5")
        var edited = original
        edited.broadcastAddress = ""
        edited.ballooningTarget = " "
        let update = edited.changes(from: original)
        #expect(update.values == ["wakeonlan": "AA:BB:CC:DD:EE:01,bind-interface=vmbr0"])
        #expect(update.deletions == ["ballooning-target"])

        var cleared = original
        cleared.macAddress = ""
        #expect(cleared.problems["wakeonlan"] != nil)
        cleared.bindInterface = ""
        cleared.broadcastAddress = ""
        #expect(cleared.problems.isEmpty && cleared.changes(from: original).deletions.contains("wakeonlan"))

        var new = NodeOptionsDraft(NodeOptions())
        new.macAddress = "bc:24:11:5a:00:03"
        #expect(new.changes(from: NodeOptionsDraft(NodeOptions())).values == ["wakeonlan": "BC:24:11:5A:00:03"])
        #expect(PVE.wakeOnLAN("pve3").path == "/nodes/pve3/wakeonlan")
    }

    @Test func hostsAndTime() throws {
        let hosts = try JSONDecoder().decode(NodeHosts.self, from: Data(#"{"data": "127.0.0.1 localhost\n", "digest": "36b4dbe2"}"#.utf8))
        #expect(hosts.text == "127.0.0.1 localhost\n" && hosts.digest == "36b4dbe2")
        #expect(PVE.updateNodeHosts("pve", text: "x", digest: "36b4dbe2").parameters.formEncoded == "data=x&digest=36b4dbe2")

        let time = try JSONDecoder().decode(NodeTime.self, from: Data(#"{"localtime": 1792601436, "timezone": "Europe/Warsaw", "time": 1792594236}"#.utf8))
        #expect(time.timeZone == "Europe/Warsaw")
        #expect(time.time == Date(timeIntervalSince1970: 1_792_594_236))

        let regions = NodeTime.zonesByRegion(["Europe/Warsaw", "America/New_York", "Europe/Berlin", "GMT"])
        #expect(regions.map(\.region) == ["America", "Europe", "UTC"])
        #expect(regions[1].zones == ["Europe/Berlin", "Europe/Warsaw"])
    }

    @Test func networkWithPendingChanges() async throws {
        let json = #"""
        {"success": 1, "data": [
          {"bridge_ports": "nic0", "gateway": "10.10.100.1", "method": "static", "priority": 4, "active": 1, "address": "10.10.100.150",
           "cidr": "10.10.100.150/24", "autostart": 1, "method6": "manual", "netmask": "24", "bridge_stp": "off", "type": "bridge",
           "families": ["inet"], "bridge_fd": "0", "iface": "vmbr0"},
          {"method": "manual", "bridge_ports": "", "autostart": 1, "priority": 5, "comments": "test\n", "iface": "vmbr9",
           "bridge_vlan_aware": 1, "bridge_vids": "2-4094", "mtu": "9000", "type": "bridge"},
          {"vlan-raw-device": "vmbr0", "method": "manual", "vlan-id": "30", "type": "vlan", "iface": "myvlan", "exists": null},
          {"method": "manual", "altnames": ["enp6s18", "enxbc2411966185"], "families": ["inet"], "priority": 3, "active": 1,
           "type": "eth", "iface": "nic0", "exists": 1}
        ],
        "changes": "--- /etc/network/interfaces\n+++ /etc/network/interfaces.new\n@@ -11,5 +22,11 @@\n+auto vmbr9\n"}
        """#
        let transport = MockResponder(response(json))
        let session = ProxmoxSession(address: ServerAddress(host: "pve", port: 8006), transport: transport)
        let network = try await session.sendUnauthenticated(PVE.network(node: "pve"))
        #expect(network.pendingChanges?.hasPrefix("--- /etc/network/interfaces") == true)
        #expect(network.sortedInterfaces.map(\.name) == ["nic0", "vmbr0", "vmbr9", "myvlan"])

        let vmbr0 = try #require(network.interfaces.first { $0.name == "vmbr0" })
        #expect(vmbr0.cidr == "10.10.100.150/24" && vmbr0.gateway == "10.10.100.1")
        #expect(vmbr0.bridgePorts == ["nic0"] && vmbr0.isActive && vmbr0.autostart)
        let vmbr9 = try #require(network.interfaces.first { $0.name == "vmbr9" })
        #expect(vmbr9.comments == "test" && vmbr9.bridgePorts.isEmpty && vmbr9.mtu == 9000)
        #expect(vmbr9.bridgeVLANAware && vmbr9.bridgeVIDs == "2-4094" && !vmbr9.isActive)
        let nic0 = try #require(network.interfaces.first { $0.name == "nic0" })
        #expect(nic0.altNames == ["enp6s18", "enxbc2411966185"] && nic0.exists == true && !nic0.isRemovable)
        #expect(network.interfaces.first { $0.name == "myvlan" }?.vlanID == 30)
        #expect(network.freeInterfaces() == ["myvlan"])
        #expect(network.freeInterfaces(excluding: "vmbr0") == ["myvlan", "nic0"])

        let clean = try await ProxmoxSession(address: ServerAddress(host: "pve", port: 8006), transport: MockResponder(response(#"{"success": 1, "data": []}"#)))
            .sendUnauthenticated(PVE.network(node: "pve"))
        #expect(clean.pendingChanges == nil && clean.interfaces.isEmpty)
    }

    @Test func olderServersReportAddressAndNetmask() throws {
        let json = #"{"iface": "vmbr0", "type": "bridge", "address": "192.168.1.5", "netmask": "255.255.255.0", "address6": "fd00::5", "netmask6": 64}"#
        let interface = try JSONDecoder().decode(NetworkInterface.self, from: Data(json.utf8))
        #expect(interface.cidr == "192.168.1.5/24")
        #expect(interface.cidr6 == "fd00::5/64")
    }

    @Test func newInterfacesGetTheFirstFreeName() throws {
        let existing = try JSONDecoder().decode([NetworkInterface].self, from: Data(#"[{"iface": "vmbr0", "type": "bridge"}, {"iface": "vmbr2", "type": "bridge"}]"#.utf8))
        #expect(NetworkInterfaceDraft(creating: .bridge, existing: existing).name == "vmbr1")
        #expect(NetworkInterfaceDraft(creating: .bond, existing: existing).name == "bond0")
        #expect(NetworkInterfaceDraft(creating: .vlan, existing: existing).name.isEmpty)
    }

    @Test func creationSendsTheSettingsOfItsType() {
        var bridge = NetworkInterfaceDraft(creating: .bridge, existing: [])
        bridge.bridgePorts = ["nic1"]
        bridge.vlanAware = true
        bridge.cidr = "192.168.77.1/24"
        bridge.comments = "Lab"
        bridge.bondSlaves = ["ignored"]
        #expect(PVE.createInterface(node: "pve", bridge).parameters.formEncoded
            == "iface=vmbr0&type=bridge&autostart=1&bridge_ports=nic1&bridge_vlan_aware=1&cidr=192.168.77.1%2F24&comments=Lab")

        var bond = NetworkInterfaceDraft(creating: .bond, existing: [])
        bond.bondSlaves = ["nic1", "nic2"]
        bond.bondMode = "802.3ad"
        bond.hashPolicy = "layer3+4"
        bond.bondPrimary = "nic1"
        #expect(PVE.createInterface(node: "pve", bond).parameters.formEncoded
            == "iface=bond0&type=bond&autostart=1&bond_mode=802.3ad&bond_xmit_hash_policy=layer3%2B4&slaves=nic1%20nic2")

        var vlan = NetworkInterfaceDraft(creating: .vlan, existing: [])
        vlan.name = "vmbr0.20"
        vlan.vlanID = "99"
        #expect(vlan.namesVLAN && vlan.problems.isEmpty)
        #expect(PVE.createInterface(node: "pve", vlan).parameters.formEncoded == "iface=vmbr0.20&type=vlan&autostart=1")
        vlan.name = "guests"
        #expect(vlan.problems.keys.sorted() == ["vlan-raw-device"])
        vlan.vlanRawDevice = "vmbr0"
        #expect(PVE.createInterface(node: "pve", vlan).parameters.formEncoded == "iface=guests&type=vlan&autostart=1&vlan-id=99&vlan-raw-device=vmbr0")
    }

    @Test func updatesSendOnlyChangesAndDeleteClearedSettings() throws {
        let json = #"{"iface": "vmbr9", "type": "bridge", "autostart": 1, "cidr": "192.168.77.1/24", "comments": "test\n", "bridge_vlan_aware": 1, "bridge_vids": "2-4094", "bridge_ports": ""}"#
        let original = NetworkInterfaceDraft(try JSONDecoder().decode(NetworkInterface.self, from: Data(json.utf8)))
        #expect(original.changes(from: original).isEmpty)

        var draft = original
        draft.mtu = "9000"
        draft.cidr = ""
        draft.comments = ""
        draft.vlanAware = false
        draft.autostart = false
        let update = draft.changes(from: original)
        #expect(update.values == ["mtu": "9000"])
        #expect(update.deletions == ["autostart", "bridge_vids", "bridge_vlan_aware", "cidr", "comments"])
        #expect(PVE.updateInterface(node: "pve", name: "vmbr9", type: "bridge", update).parameters.formEncoded
            == "mtu=9000&delete=autostart%2Cbridge_vids%2Cbridge_vlan_aware%2Ccidr%2Ccomments&type=bridge")
    }

    @Test func problems() {
        var draft = NetworkInterfaceDraft(creating: .bridge, existing: [])
        #expect(draft.problems.isEmpty)
        draft.name = "bad name!"
        draft.mtu = "100"
        draft.gateway = "10.0.0.1"
        draft.cidr6 = "fd00::1"
        #expect(draft.problems.keys.sorted() == ["cidr6", "gateway", "iface", "mtu"])
        #expect(NetworkInterface.prefixLength("255.255.240.0") == "20")
    }
}

/// Answers every request with the same response.
private struct MockResponder: HTTPTransport {
    let response: HTTPResponse

    init(_ response: HTTPResponse) { self.response = response }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse { response }
}
