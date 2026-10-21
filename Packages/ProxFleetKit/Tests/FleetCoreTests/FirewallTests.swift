import DemoServer
@testable import FleetCore
import Foundation
import ProxmoxCore
import PVEKit
import Testing

@MainActor
struct FirewallModelTests {
    private func connection(username: String = "root") async throws -> ServerConnection {
        let transport = DemoTransport(cluster: .homelab)
        let environment = FleetEnvironment(profiles: InMemoryServerProfileStore(), credentials: InMemoryCredentialStore()) { _ in transport }
        let fleet = Fleet(environment: environment)
        let profile = fleet.addSaved(ServerProfile(name: "lab", addresses: [ServerAddress(host: "demo", port: 8006)], username: username, realm: username == "root" ? "pam" : "pve"), password: "pw")
        let connection = try #require(fleet.connection(for: profile.id))
        await connection.connect()
        try #require(connection.state == .connected)
        return connection
    }

    @Test func datacenterRules() async throws {
        let firewall = Firewall(connection: try await connection(), scope: .datacenter)
        await firewall.load()
        #expect(firewall.isEnabled && firewall.canModify && firewall.isDatacenterEnabled == true)
        #expect(firewall.rules?.count == 3 && firewall.groups?.map(\.name) == ["ssh-admin", "webserver"])
        #expect(firewall.aliases?.map(\.name) == ["admin-laptop", "lan"] && firewall.ipSets?.map(\.name) == ["blacklist", "management"])

        await firewall.loadEditorChoices()
        #expect(firewall.macros.contains { $0.name == "SSH" } && firewall.references.contains { $0.reference == "+management" })

        var draft = FirewallRuleDraft()
        draft.macro = "HTTPS"
        draft.source = "lan"
        draft.comment = "Reverse proxy"
        try await firewall.createRule(draft)
        // New rules go to the top.
        #expect(firewall.rules?.first?.comment == "Reverse proxy")

        let created = try #require(firewall.rules?.first)
        try await firewall.moveRule(from: 0, to: 4)
        #expect(firewall.rules?.last?.comment == "Reverse proxy")
        let moved = try #require(firewall.rules?.last)
        try await firewall.setEnabled(moved, false)
        #expect(firewall.rules?.last?.isEnabled == false)

        var edit = FirewallRuleDraft(try #require(firewall.rules?.last))
        edit.source = "nowhere"
        await #expect(throws: ConfigUpdateError.invalid(message: "Parameter verification failed.", fields: ["source": "no such alias 'nowhere'"])) {
            try await firewall.updateRule(try #require(firewall.rules?.last), edit.changes(from: FirewallRuleDraft(try #require(firewall.rules?.last))))
        }
        // A stale digest is refused and the current rules are loaded.
        await #expect(throws: ConfigUpdateError.conflict) { try await firewall.deleteRule(created) }
        try await firewall.deleteRule(try #require(firewall.rules?.last))
        #expect(firewall.rules?.count == 3)
    }

    @Test func aliasesIPSetsAndGroups() async throws {
        let firewall = Firewall(connection: try await connection(), scope: .datacenter)
        await firewall.load()

        try await firewall.createAlias(name: "nas", cidr: "10.0.10.5", comment: "")
        let nas = try #require(firewall.aliases?.first { $0.name == "nas" })
        try await firewall.updateAlias(nas, name: "storage", cidr: "10.0.10.6", comment: "TrueNAS")
        #expect(firewall.aliases?.first { $0.name == "storage" }?.comment == "TrueNAS")

        try await firewall.saveIPSet(name: "backup", comment: "")
        try await firewall.addEntry(to: "backup", cidr: "storage", comment: "", excluded: false)
        try await firewall.addEntry(to: "backup", cidr: "10.0.20.0/24", comment: "Offsite", excluded: true)
        #expect(firewall.ipSetEntries["backup"]?.map(\.cidr) == ["storage", "10.0.20.0/24"])
        let network = try #require(firewall.ipSetEntries["backup"]?.last)
        try await firewall.updateEntry(network, in: "backup", comment: "", excluded: false)
        #expect(firewall.ipSetEntries["backup"]?.last?.isExcluded == false)
        try await firewall.deleteEntry(network, from: "backup")
        #expect(firewall.ipSetEntries["backup"]?.count == 1)
        let backup = try #require(firewall.ipSets?.first { $0.name == "backup" })
        try await firewall.saveIPSet(name: "backups", comment: "Backup targets", renaming: backup)
        #expect(firewall.ipSetEntries["backups"]?.count == 1)
        try await firewall.deleteIPSet(try #require(firewall.ipSets?.first { $0.name == "backups" }))
        #expect(firewall.ipSets?.map(\.name) == ["blacklist", "management"])

        // Renaming a group updates the rules that apply it.
        let ssh = try #require(firewall.groups?.first { $0.name == "ssh-admin" })
        try await firewall.saveGroup(name: "ssh", comment: "", renaming: ssh)
        #expect(firewall.rules?.contains { $0.isGroup && $0.action == "ssh" } == true)
        let group = firewall.group("ssh")
        await group.load()
        #expect(group.rules?.first?.macro == "SSH" && group.options == nil)
        await #expect(throws: ConfigUpdateError.self) { try await firewall.deleteGroup(try #require(firewall.groups?.first { $0.name == "ssh" })) }
        try await group.deleteRule(try #require(group.rules?.first))
        try await firewall.saveGroup(name: "empty", comment: "")
        try await firewall.deleteGroup(try #require(firewall.groups?.first { $0.name == "empty" }))
        #expect(firewall.groups?.map(\.name) == ["ssh", "webserver"])
    }

    @Test func nodeAndGuest() async throws {
        let connection = try await connection()
        let node = Firewall(connection: connection, scope: .node("pve1"))
        await node.load()
        #expect(node.isEnabled && node.rules?.first?.destinationPort == "9100" && node.aliases == nil && node.isDatacenterEnabled == true)
        var options = FirewallOptionsDraft(try #require(node.options), scope: .node("pve1"))
        let original = options
        options.setFlag("tcpflags", true)
        try await node.saveOptions(options.changes(from: original))
        #expect(node.options?.values["tcpflags"] == "1")
        let lines = try await node.loadLog(lines: 10)
        #expect(lines.count == 10 && lines.last?.number == 25)

        let guest = Firewall(connection: connection, scope: .guest(GuestReference(node: "pve1", vmid: 100, kind: .virtualMachine)))
        await guest.load()
        #expect(guest.isEnabled && guest.rules?.count == 3 && guest.aliases?.map(\.name) == ["tablet"])
        await guest.loadEditorChoices()
        #expect(guest.references.contains { $0.scope == "guest" && $0.name == "tablet" } && guest.references.contains { $0.scope == "dc" })
        try await guest.setEnabled(false)
        #expect(!guest.isEnabled)

        let auditor = Firewall(connection: try await self.connection(username: "auditor"), scope: .guest(GuestReference(node: "pve1", vmid: 100, kind: .virtualMachine)))
        await auditor.load()
        #expect(!auditor.canModify)
        await #expect(throws: ConfigUpdateError.self) { try await auditor.setEnabled(true) }
    }
}
