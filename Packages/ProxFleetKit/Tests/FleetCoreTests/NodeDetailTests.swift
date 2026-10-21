import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct NodeDetailTests {
    private func connection(username: String = "root") async throws -> ServerConnection {
        let transport = DemoTransport(cluster: .homelab)
        let environment = FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in transport }
        let fleet = Fleet(environment: environment)
        let profile = fleet.addSaved(ServerProfile(name: "lab", addresses: [ServerAddress(host: "demo", port: 8006)], username: username, realm: "pve"), password: "pw")
        let connection = try #require(fleet.connection(for: profile.id))
        await connection.connect()
        try #require(connection.state == .connected)
        return connection
    }

    @Test func loadsStatusHistoryAndLists() async throws {
        let detail = NodeDetail(node: "pve1", connection: try await connection())
        await detail.load()
        let status = try #require(detail.status)
        #expect(status.cpuCount == 16 && status.memoryTotal > 0 && status.loadAverage.count == 3)
        #expect(status.pveVersion == "9.0.10")
        #expect(detail.history.contains { $0.loadAverage != nil })
        #expect(detail.can("Sys.PowerMgmt"))

        #expect(await detail.loadServices() == nil)
        #expect(detail.services?.first { $0.name == "pveproxy" }?.isRunning == true)
        #expect(await detail.loadUpdates() == nil)
        #expect(detail.updates?.map(\.package) == ["pve-manager", "proxmox-widget-toolkit"])
        #expect(detail.versions?.contains { $0.runningKernel != nil } == true)
        #expect(await detail.loadJournal(lastEntries: 20) == nil)
        #expect(detail.journal?.count == 20)
        #expect(detail.journal?.allSatisfy { $0.contains("pve1") } == true)
    }

    @Test func serviceActionsAndPackageRefreshAreTracked() async throws {
        let connection = try await connection()
        let detail = NodeDetail(node: "pve1", connection: connection)
        await detail.loadServices()
        let chrony = try #require(detail.services?.first { $0.name == "chrony" })
        try await detail.perform(.stop, on: chrony)
        #expect(detail.services?.first { $0.name == "chrony" }?.isRunning == false)
        try await detail.refreshPackageIndex()
        #expect(connection.tasks.tasks.first?.title == "Update Package Database")
        await detail.loadTasks()
        #expect(detail.tasks?.map(\.type).prefix(2) == ["aptupdate", "srvstop"])
    }

    @Test func rebootTakesTheNodeOffline() async throws {
        let connection = try await connection()
        let detail = NodeDetail(node: "pve2", connection: connection)
        try await detail.power(.reboot)
        await connection.refresh()
        #expect(connection.snapshot?.nodes.first { $0.name == "pve2" }?.isOnline == false)
        #expect(connection.snapshot?.guests.filter { $0.node == "pve2" }.allSatisfy { $0.state != .running } == true)
    }

    @Test func auditorCannotRestartServices() async throws {
        let detail = NodeDetail(node: "pve1", connection: try await connection(username: "auditor"))
        await detail.load()
        #expect(!detail.can("Sys.Modify"))
        await detail.loadServices()
        let cron = try #require(detail.services?.first { $0.name == "cron" })
        await #expect(throws: ConfigUpdateError.self) {
            try await detail.perform(.restart, on: cron)
        }
    }

    @Test func systemSettings() async throws {
        let detail = NodeDetail(node: "pve1", connection: try await connection())
        #expect(await detail.loadSystemSettings() == nil)
        #expect(detail.dns?.searchDomain == "home.arpa")
        #expect(detail.hosts?.text.contains("10.0.10.11 pve1.home.arpa pve1") == true)
        #expect(detail.time?.timeZone == "Europe/Berlin")

        try await detail.saveDNS(NodeDNS(searchDomain: "lab.example", servers: ["", "9.9.9.9", ""]))
        #expect(detail.dns == NodeDNS(searchDomain: "lab.example", servers: ["9.9.9.9"]))
        await #expect(throws: ConfigUpdateError.invalid(message: "Parameter verification failed.", fields: ["dns1": "value does not look like a valid IP address"])) {
            try await detail.saveDNS(NodeDNS(searchDomain: "lab", servers: ["nope"]))
        }

        let text = (detail.hosts?.text ?? "") + "10.0.10.50 nas\n"
        try await detail.saveHosts(text)
        #expect(detail.hosts?.text == text)

        try await detail.setTimeZone("Europe/Warsaw")
        #expect(detail.time?.timeZone == "Europe/Warsaw")
        await #expect(throws: ConfigUpdateError.self) { try await detail.setTimeZone("Mars/Olympus") }
    }

    @Test func hostsConflictWhenChangedElsewhere() async throws {
        let connection = try await connection()
        let first = NodeDetail(node: "pve1", connection: connection)
        let second = NodeDetail(node: "pve1", connection: connection)
        await first.loadSystemSettings()
        await second.loadSystemSettings()
        try await first.saveHosts("127.0.0.1 localhost\n")
        await #expect(throws: ConfigUpdateError.conflict) { try await second.saveHosts("127.0.0.1 other\n") }
    }

    @Test func networkChangesWaitForApply() async throws {
        let connection = try await connection()
        let detail = NodeDetail(node: "pve1", connection: connection)
        #expect(await detail.loadNetwork() == nil)
        let network = try #require(detail.network)
        #expect(network.pendingChanges == nil)
        #expect(network.sortedInterfaces.map(\.name) == ["nic0", "nic1", "vmbr0", "vmbr1"])

        var bridge = NetworkInterfaceDraft(creating: .bridge, existing: network.interfaces)
        #expect(bridge.name == "vmbr2")
        bridge.cidr = "192.168.50.1/24"
        bridge.comments = "Isolated"
        try await detail.createInterface(bridge)
        let pending = try #require(detail.network?.pendingChanges)
        #expect(pending.contains("+auto vmbr2") && pending.contains("+\taddress 192.168.50.1/24"))
        #expect(detail.network?.interfaces.first { $0.name == "vmbr2" }?.isActive == false)

        // Proxmox refuses a second default gateway and ports used elsewhere.
        var other = NetworkInterfaceDraft(creating: .bridge, existing: detail.network?.interfaces ?? [])
        other.gateway = "192.168.60.254"
        other.cidr = "192.168.60.1/24"
        other.bridgePorts = ["nic0"]
        await #expect(throws: ConfigUpdateError.self) { try await detail.createInterface(other) }

        let vmbr1 = try #require(detail.network?.interfaces.first { $0.name == "vmbr1" })
        var edit = NetworkInterfaceDraft(vmbr1)
        edit.mtu = "9000"
        edit.vlanAware = false
        try await detail.updateInterface("vmbr1", type: "bridge", edit.changes(from: NetworkInterfaceDraft(vmbr1)))
        let edited = try #require(detail.network?.interfaces.first { $0.name == "vmbr1" })
        #expect(edited.mtu == 9000 && !edited.bridgeVLANAware && edited.bridgeVIDs == nil)

        try await detail.revertNetwork()
        #expect(detail.network?.pendingChanges == nil)
        #expect(detail.network?.interfaces.count == 4)

        try await detail.createInterface(bridge)
        try await detail.applyNetwork()
        #expect(detail.network?.pendingChanges == nil)
        #expect(detail.network?.interfaces.first { $0.name == "vmbr2" }?.isActive == true)
        #expect(try await connection.send(PVE.bridges(node: "pve1")).map(\.name).contains("vmbr2"))

        try await detail.deleteInterface("vmbr2")
        #expect(detail.network?.pendingChanges?.contains("-auto vmbr2") == true)
    }

    @Test func auditorCannotChangeSettings() async throws {
        let detail = NodeDetail(node: "pve1", connection: try await connection(username: "auditor"))
        await detail.loadSystemSettings()
        await #expect(throws: ConfigUpdateError.self) { try await detail.setTimeZone("UTC") }
        await detail.loadNetwork()
        await #expect(throws: ConfigUpdateError.self) { try await detail.revertNetwork() }
    }
}
